"""Many small WSGI sites (Django, Flask, ...) on one small server.

    python -m nexcore_turbo.multisite serve            # the site server (run as root, PID 1 in Docker)
    python -m nexcore_turbo.multisite run SITE CMD...  # run a command as that site (migrate, shell, ...)

Every site is a directory TURBO_SITES/<name>/ owned by the site's own uid:

    app/        the project; put on sys.path
    lib/        optional extra packages (pip install --target lib)
    turbo.env   KEY=VALUE lines, read only after dropping to the site's uid.
                TURBO_WSGI=project.wsgi:application is required; every line
                becomes an environment variable of the site.

The server binds TURBO_SOCKETS/<name>.sock for each site but starts nothing.
Three things keep the memory low:

  * scale to zero: the first connection forks a child that serves the site
    with gunicorn; after TURBO_IDLE seconds without requests it exits, so idle
    sites use no memory at all.
  * shared preload: the server imports the framework (TURBO_PRELOAD, default
    django, gunicorn and the common markdown / Pillow / Pygments when installed)
    once and freezes the GC before forking, so every site shares one copy of it
    copy-on-write.
  * TURBO_MAX_ACTIVE=auto (default): the number of sites running at once follows
    the memory budget (TURBO_MEMORY_BUDGET, else the container limit), measured
    from the sites running now; past it the longest-idle site is stopped.
  * the child drops to the site's uid/gid before it reads anything of the
    site, keeps only its own socket, and loads its app before gunicorn forks
    the worker (see warmup.py).

SIGHUP rescans TURBO_SITES; SIGTERM stops every site and exits.

One site must never take the others down, so each site child gets its own limits:
TURBO_SITE_MEMORY / TURBO_SITE_PIDS / TURBO_SITE_CPUS as a cgroup v2 group when
TURBO_CGROUP names a writable cgroup2 directory that holds this server's cgroup
(a cgroup that only runs out inside that site), always RLIMIT_NPROC on the site's
uid and a high oom_score_adj (a memory shortage kills a site, not the server),
and a private TMPDIR. The server itself never exits on an error: a site it
can't start answers 503 and is retried later.
"""

import ctypes
import errno
import gc
import importlib
import logging
import mmap
import os
import pkgutil
import re
import resource
import selectors
import shutil
import signal
import socket
import struct
import sys
import time

SITES = os.environ.get("TURBO_SITES", "/srv/sites")
SOCKETS = os.environ.get("TURBO_SOCKETS", "/run/turbo")
IDLE = float(os.environ.get("TURBO_IDLE", "60"))
MAX_ACTIVE_SPEC = os.environ.get("TURBO_MAX_ACTIVE", "auto").strip().lower()   # a number, or auto: fit TURBO_MEMORY_BUDGET
MEMORY_BUDGET = os.environ.get("TURBO_MEMORY_BUDGET", "")   # sites + server; default: container limit, else 90% of RAM
AUTO_START = 16                                             # auto: slots before enough running sites were measured
MIN_UID = int(os.environ.get("TURBO_MIN_UID", "1000"))
SOCKET_GID = int(os.environ.get("TURBO_SOCKET_GID", "-1"))
SITE_WORKERS = int(os.environ.get("TURBO_SITE_WORKERS", "2"))   # pages nginx can't cache (forms set a CSRF cookie) must not queue behind one request
# Sync workers by default: they accept one connection at a time, so stopping an
# idle site never drops a connection that was already taken off the queue
# (a gthread worker accepts ahead and would reset those).
SITE_THREADS = int(os.environ.get("TURBO_SITE_THREADS", "1"))
MAX_WORKERS = int(os.environ.get("TURBO_SITE_MAX_WORKERS", "4"))
SITE_TIMEOUT = int(os.environ.get("TURBO_SITE_TIMEOUT", "30"))
# A site with requests in flight is never stopped (idle or evicted). A count that outlives the
# request timeout by this much is a leftover of a worker that died mid-request, not real work.
BUSY_GRACE = 15
LOG_MAX = int(os.environ.get("TURBO_LOG_MAX", str(5 << 20)))   # bytes; the site log is rotated past this
DEFAULT_PRELOAD = "django,gunicorn,markdown,PIL,pygments"   # missing ones are skipped silently
CGROUP = os.environ.get("TURBO_CGROUP", "")
SITE_MEMORY = os.environ.get("TURBO_SITE_MEMORY", "512M")
SITE_PIDS = int(os.environ.get("TURBO_SITE_PIDS", "128"))       # processes + threads of one site
SITE_CPUS = float(os.environ.get("TURBO_SITE_CPUS", "1"))
LOCK_TMP = os.environ.get("TURBO_LOCK_TMP", "") in ("1", "true", "yes")
# With TURBO_CGROUP set, a site never runs without its memory and process limits: if they can't
# be set, the server refuses to start (or the site answers 503) instead of quietly running unlimited.
REQUIRE_LIMITS = os.environ.get("TURBO_REQUIRE_LIMITS", "1" if CGROUP else "0") in ("1", "true", "yes")
CRITICAL_LIMITS = ("memory.max", "pids.max")
# Site starts per second, all sites together: a flood of uncached requests across many sites
# can't turn the server into a fork loop. Over the rate, sites wait (they are not refused).
SPAWN_RATE = float(os.environ.get("TURBO_SPAWN_RATE", "20"))
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,40}$")
# __main__: old gunicorn releases start a server when gunicorn.__main__ is imported.
SKIP_MODULES = re.compile(r"\.(tests?|testing|gis|oracle|mysql|postgresql|__main__|ImageTk|_tkinter_finder)(\.|$)|^django\.contrib\.gis|^PIL\.(features|report)$")   # they probe Tk / print a report on import

log = logging.getLogger("nexcore_turbo.multisite")


# ---------------------------------------------------------------- site child

def _read_env(path):
    env = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key = key.strip()
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
                env[key] = value.strip().strip('"').strip("'")
    return env


def become(name):
    """Drop to the site's uid/gid and switch to its environment. Returns site dir."""
    home = os.path.join(SITES, name)
    st = os.lstat(home)
    if not NAME_RE.match(name) or not os.path.isdir(home) or os.path.islink(home) or st.st_uid < MIN_UID:
        raise SystemExit("refusing site %r: needs a directory owned by uid >= %d" % (name, MIN_UID))
    os.setgroups([])
    os.setgid(st.st_gid if st.st_gid >= MIN_UID else st.st_uid)
    os.setuid(st.st_uid)
    os.umask(0o022)   # app/, lib/ and data/ are 0700 anyway; static/ must stay readable for nginx
    env = {
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "LANG": os.environ.get("LANG", "C.UTF-8"),
        "HOME": home,
        "TURBO_SITE": name,
        "TMPDIR": os.path.join(home, "tmp"),   # never the shared /tmp: other sites could read our files there
        "PYTHONPATH": os.path.join(home, "lib"),
    }
    env.update(_read_env(os.path.join(home, "turbo.env")))   # after setuid: a symlink can't leak root files
    try:
        os.makedirs(env["TMPDIR"], 0o700, exist_ok=True)
    except OSError:
        env["TMPDIR"] = "/tmp"
    os.environ.clear()
    os.environ.update(env)
    app_dir = os.path.join(home, "app")
    os.chdir(app_dir)
    sys.path[:0] = [app_dir, os.path.join(home, "lib")]
    _unshadow(os.path.join(home, "lib"))
    return home


def _limit_self():
    """Root, before become(): limits that hold even without cgroups."""
    resource.setrlimit(resource.RLIMIT_NPROC, (SITE_PIDS, SITE_PIDS))   # counted per uid = per site
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    try:
        with open("/proc/self/oom_score_adj", "w") as fh:   # out of memory: a site goes first, never the server
            fh.write("800")
    except OSError:
        pass


def _size(value):
    value = value.strip().lower()
    if value in ("", "0", "max"):
        return "max"
    m = re.match(r"^(\d+)([kmg]?)b?$", value)
    if not m:
        raise SystemExit("bad size %r (use 512M, 1G, max)" % value)
    return str(int(m.group(1)) << {"": 0, "k": 10, "m": 20, "g": 30}[m.group(2)])


def _anon(path="/sys/fs/cgroup"):
    """anon + shmem bytes of a cgroup (not page cache: the kernel drops that under pressure)."""
    try:
        with open(os.path.join(path, "memory.stat"), encoding="ascii") as f:
            stat = dict(line.split() for line in f)
        return int(stat["anon"]) + int(stat.get("shmem", 0))
    except (OSError, ValueError, KeyError):
        return 0


def _budget():
    """Memory the server and its sites may use, in bytes."""
    if MEMORY_BUDGET:
        size = _size(MEMORY_BUDGET)
        if size != "max":
            return int(size)
    try:
        with open("/sys/fs/cgroup/memory.max") as f:   # the container's own limit (cgroup namespace)
            value = f.read().strip()
        if value != "max":
            return int(value)
    except (OSError, ValueError):
        pass
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemTotal:"):
                return int(line.split()[1]) * 1024 * 9 // 10
    return 2 << 30


def _cg_read(path, name):
    with open(os.path.join(path, name), encoding="ascii") as fh:
        return fh.read()


def _cg_write(path, name, value):
    with open(os.path.join(path, name), "w", encoding="ascii") as fh:
        fh.write(value)


class Cgroups:
    """Per-site cgroup v2 groups below the server's own (delegated) cgroup:

        <own>/supervisor     the server and anything exec'd into the container
        <own>/site-<name>    one site, with its memory / pids / cpu limits

    TURBO_CGROUP is a writable cgroup2 directory that contains <own> (Docker:
    cgroup_parent: turbo.slice + /sys/fs/cgroup/turbo.slice mounted there) or is
    <own> itself (systemd: Delegate=yes)."""

    def __init__(self, root, setup):
        self.own = self._find(root)
        self.limits = [("memory.max", _size(SITE_MEMORY)), ("memory.swap.max", "0"), ("memory.oom.group", "1"),
                       ("pids.max", str(SITE_PIDS)),
                       ("cpu.max", "%d 100000" % (SITE_CPUS * 100000) if SITE_CPUS > 0 else "max")]
        if not setup:
            return
        sup = os.path.join(self.own, "supervisor")
        os.makedirs(sup, exist_ok=True)
        for _ in range(5):   # cgroup v2: no processes next to child groups, so move everyone down first
            pids = [p for p in _cg_read(self.own, "cgroup.procs").split() if p != "0"]
            if not pids:
                break
            for pid in pids:
                try:
                    _cg_write(sup, "cgroup.procs", pid)
                except OSError:
                    pass                          # already gone
        have = set(_cg_read(self.own, "cgroup.controllers").split())
        want = [c for c in ("memory", "pids", "cpu") if c in have]
        _cg_write(self.own, "cgroup.subtree_control", " ".join("+" + c for c in want))

    @staticmethod
    def _find(root):
        me = str(os.getpid())
        dirs = [root] + sorted(os.path.join(root, d) for d in os.listdir(root) if os.path.isdir(os.path.join(root, d)))
        for cg in dirs:
            for d in (cg, os.path.join(cg, "supervisor")):
                try:
                    if me in _cg_read(d, "cgroup.procs").split():
                        return cg
                except OSError:
                    pass
        raise OSError("TURBO_CGROUP=%s does not hold this process's cgroup" % root)

    def site(self, name):
        """The site's group with its limits (re)applied; returns its path."""
        path = os.path.join(self.own, "site-" + name)
        os.makedirs(path, exist_ok=True)
        missing = []
        for key, value in self.limits:
            try:
                _cg_write(path, key, value)
            except OSError:
                if key in CRITICAL_LIMITS:        # others are optional: no swap accounting, older kernel, ...
                    missing.append(key)
        if missing:
            raise OSError("cannot set %s" % ", ".join(missing))
        return path

    def drop(self, name):
        try:
            os.rmdir(os.path.join(self.own, "site-" + name))
        except OSError:
            pass


def _unshadow(lib):
    """A site that ships its own copy of a preloaded package (another Django version) gets its copy."""
    for top in {m.partition(".")[0] for m in list(sys.modules)}:
        if top in ("gunicorn", "nexcore_turbo") or not os.path.isdir(os.path.join(lib, top)):
            continue
        for mod in [m for m in sys.modules if m == top or m.startswith(top + ".")]:
            del sys.modules[mod]


COMPRESS_TYPES = re.compile(r"^(text/|application/(json|javascript|xml|rss\+xml|atom\+xml|ld\+json)|image/svg\+xml)")
COMPRESS_MAX = 8 << 20   # bigger bodies are streamed as they are (nginx gzips those)


def _compressing(app):
    """gzip the response once, in the app, when nginx marks the request cacheable
    (X-Turbo-Compress: 1, set by nginx only for anonymous cookie-less GET/HEAD), so the
    cache stores it compressed and a hit is sent without gzipping it again. Never a
    response that sets a cookie or is private: those may hold a secret (BREACH)."""
    import gzip

    def wrapped(environ, start_response):
        if environ.get("HTTP_X_TURBO_COMPRESS") != "1" or environ.get("REQUEST_METHOD") != "GET":
            return app(environ, start_response)
        held = {}

        def capture(status, headers, exc_info=None):
            if exc_info:
                held.clear()
                return start_response(status, headers, exc_info)
            held.update(status=status, headers=headers)
            return held.setdefault("write", lambda data: held.setdefault("early", []).append(data))

        result = app(environ, capture)
        if "status" not in held:                     # exc_info path: already started
            return result
        status, headers = held["status"], held["headers"]
        names = {k.lower(): v for k, v in headers}
        cc = names.get("cache-control", "").lower()
        if (not status.startswith("200") or "content-encoding" in names or "set-cookie" in names
                or "private" in cc or "no-store" in cc or not COMPRESS_TYPES.match(names.get("content-type", ""))):
            write = start_response(status, headers)
            for data in held.get("early", []):
                write(data)
            return result
        try:
            body, size = list(held.get("early", [])), 0
            for chunk in result:
                body.append(chunk)
                size += len(chunk)
                if size > COMPRESS_MAX:
                    break
        finally:
            if size <= COMPRESS_MAX and hasattr(result, "close"):
                result.close()
        if size > COMPRESS_MAX:                      # too big to hold: send it as it is
            write = start_response(status, headers)
            def rest():
                try:
                    yield from body
                    yield from result
                finally:
                    if hasattr(result, "close"):
                        result.close()
            return rest()
        raw = b"".join(body)
        if len(raw) < 1024:
            start_response(status, headers)
            return [raw]
        packed = gzip.compress(raw, 6, mtime=0)
        # No "Vary: Accept-Encoding" here: nginx would keep one cached copy per Accept-Encoding
        # string and a refresh would replace only one of them. nginx adds it for the browser.
        headers = [(k, v) for k, v in headers if k.lower() not in ("content-length", "etag")]
        if names.get("etag"):
            etag = names["etag"]
            headers.append(("ETag", etag if etag.startswith("W/") else "W/" + etag))
        headers += [("Content-Encoding", "gzip"), ("Content-Length", str(len(packed)))]
        start_response(status, headers)
        return [packed]

    return wrapped


def _counter_lock():
    """A lock shared by the site's master, its workers and their threads (created before gunicorn
    forks the workers). POSIX semaphore when /dev/shm is usable, else an flock'd file in TMPDIR."""
    try:
        import multiprocessing
        return multiprocessing.Lock()
    except (OSError, ImportError):
        import fcntl
        import threading

        class FileLock:
            path = os.path.join(os.environ.get("TMPDIR", "/tmp"), ".turbo-busy.lock")

            def __init__(self):
                self.t = threading.Lock()
                self.pid = self.fd = None

            def acquire(self, timeout=None):
                if not self.t.acquire(timeout=-1 if timeout is None else timeout):
                    return False
                if self.pid != os.getpid():       # forked worker: its own open file, or flock won't exclude
                    self.fd, self.pid = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600), os.getpid()
                fcntl.flock(self.fd, fcntl.LOCK_EX)
                return True

            def release(self):
                fcntl.flock(self.fd, fcntl.LOCK_UN)
                self.t.release()

            __enter__ = acquire

            def __exit__(self, *exc):
                self.release()

        return FileLock()


def _load(spec):
    module, _, attr = spec.partition(":")
    obj = importlib.import_module(module)
    for part in (attr or "application").split("."):
        obj = getattr(obj, part)
    return obj


def serve_site(name, fd, shared):
    """Child: serve one site on the listening socket `fd` until idle.

    `shared` is an 8-byte shared mapping holding the time of the last request;
    the server reads it to pick which running site to stop when MAX_ACTIVE is reached.
    """
    for sig in (signal.SIGCHLD, signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, signal.SIG_DFL)
    signal.set_wakeup_fd(-1)
    # Keep only stdio and our own socket (as fd 3, systemd style): never other sites' sockets.
    if fd != 3:
        os.dup2(fd, 3)
    os.closerange(4, 65536)
    become(name)
    tmp = os.environ["TMPDIR"]
    if tmp != "/tmp":                             # left over from the last run
        for entry in os.listdir(tmp):
            p = os.path.join(tmp, entry)
            try:
                shutil.rmtree(p) if os.path.isdir(p) and not os.path.islink(p) else os.unlink(p)
            except OSError:
                pass
    logfile = os.environ.get("TURBO_LOG_FILE")   # per-site log, start-up errors included; rotated past TURBO_LOG_MAX

    def open_log():
        out = os.open(logfile, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        os.dup2(out, 1)
        os.dup2(out, 2)
        os.close(out)

    if logfile:
        if os.path.exists(logfile) and os.path.getsize(logfile) > LOG_MAX:
            os.replace(logfile, logfile + ".1")
        open_log()
    try:  # setuid made us non-dumpable: let the site's own tools (ps, py-spy) see its processes
        ctypes.CDLL(None).prctl(4, 1, 0, 0, 0)   # PR_SET_DUMPABLE
    except (OSError, AttributeError):
        pass
    from gunicorn.app.base import BaseApplication

    from nexcore_turbo.warmup import close_shared_resources, paths_from_env, warm

    spec = os.environ.get("TURBO_WSGI")
    if not spec:
        raise SystemExit("%s: TURBO_WSGI is not set in turbo.env" % name)
    app = _compressing(_load(spec))
    paths = paths_from_env()
    if paths:
        warm(app, paths, logger=log)          # also closes DB sockets and freezes the GC
    else:
        close_shared_resources()
        gc.collect()
        gc.freeze()

    last = ctypes.c_double.from_buffer(shared)          # written by the worker(s), read by our master and the server
    busy = ctypes.c_int64.from_buffer(shared, 8)         # requests in flight, same readers
    lock = _counter_lock()
    timeout = int(os.environ.get("TURBO_SITE_TIMEOUT", SITE_TIMEOUT))

    def touch(*_):
        last.value = time.monotonic()

    def check_idle(*_):
        idle = time.monotonic() - last.value
        if busy.value > 0 and idle > timeout + BUSY_GRACE and lock.acquire(timeout=0.1):
            try:
                busy.value = 0                    # a worker died mid-request and never counted down
            finally:
                lock.release()
        if idle > IDLE and busy.value <= 0:
            signal.setitimer(signal.ITIMER_REAL, 0)
            os.kill(os.getpid(), signal.SIGTERM)  # graceful: in-flight requests finish
            return
        if logfile:                               # a busy site must not fill the disk before it goes idle
            try:
                if os.path.getsize(logfile) > LOG_MAX:
                    os.replace(logfile, logfile + ".1")
                    open_log()
                    os.kill(os.getpid(), signal.SIGUSR1)   # gunicorn: reopen the log in master and workers
            except OSError:
                pass

    def when_ready(server):
        touch()   # 0 until now: the server never stops a site that is still starting
        # A timer in the master only (itimers are not inherited by forked workers).
        signal.signal(signal.SIGALRM, check_idle)
        signal.setitimer(signal.ITIMER_REAL, 1, 1)

    def pre_request(worker, req):
        with lock:
            busy.value += 1
        touch()

    def post_request(worker, req, environ, resp):
        with lock:
            busy.value = max(0, busy.value - 1)
        touch()

    workers = max(1, min(int(os.environ.get("TURBO_SITE_WORKERS", SITE_WORKERS)), MAX_WORKERS))
    threads = max(1, min(int(os.environ.get("TURBO_SITE_THREADS", SITE_THREADS)), 16))
    options = {
        "workers": workers,
        "threads": threads,
        "worker_class": "gthread" if threads > 1 else "sync",
        "keepalive": 0,                       # gthread: never hold idle connections, or stopping an idle site waits for them
        "timeout": timeout,
        "graceful_timeout": 10,
        "max_requests": 2000,
        "max_requests_jitter": 200,
        "proc_name": "turbo-" + name,
        "user": os.getuid(),                  # gunicorn's defaults were computed while still root
        "group": os.getgid(),
        "errorlog": logfile or "-",
        "accesslog": logfile,
        "loglevel": os.environ.get("TURBO_LOG_LEVEL", "warning"),
        # behind nginx on a unix socket: log the visitor, not "-"
        "access_log_format": '%({x-real-ip}i)s %(l)s %(u)s %(t)s "%(r)s" %(s)s %(b)s "%(f)s" "%(a)s"',
        "control_socket_disable": True,       # gunicorn >= 26: its default path was computed as root
        "when_ready": when_ready,
        "pre_request": pre_request,
        "post_request": post_request,
    }

    class Site(BaseApplication):
        def load_config(self):
            for key, value in options.items():
                if key in self.cfg.settings:      # older gunicorn lacks some settings
                    self.cfg.set(key, value)

        def load(self):
            return app

    os.environ["LISTEN_FDS"] = "1"            # gunicorn adopts fd 3 and leaves the socket file alone
    os.environ["LISTEN_PID"] = str(os.getpid())
    sys.argv = ["turbo-" + name]
    Site().run()


# ---------------------------------------------------------------- server

def preload(spec, quiet=False):
    """Import the shared framework once; only modules that import without settings stay."""
    before = len(sys.modules)
    for pkg in [p.strip() for p in spec.split(",") if p.strip()]:
        try:
            root = importlib.import_module(pkg)
        except Exception:
            if not quiet:
                log.warning("preload: %s not importable", pkg)
            continue
        for info in pkgutil.walk_packages(getattr(root, "__path__", []), pkg + ".", onerror=lambda _: None):
            if SKIP_MODULES.search(info.name):
                continue
            try:
                importlib.import_module(info.name)
            except BaseException:  # needs settings, optional dependency, ...: the site imports it itself
                pass
    gc.collect()
    gc.freeze()
    return len(sys.modules) - before


class Server:
    def __init__(self):
        self.sel = selectors.DefaultSelector()
        self.sites = {}        # name -> {"sock", "pid", "started", "fails", "until"}
        self.children = {}     # pid -> name
        self.waiting = []      # sites with connections queued while MAX_ACTIVE was reached
        self.flags = set()
        self.want_stop = False
        self.retry_at = 0      # a site that could not be added is retried then
        self.auto = not MAX_ACTIVE_SPEC.isdigit()
        self.max_active = AUTO_START if self.auto else int(MAX_ACTIVE_SPEC)
        self.budget = _budget() if self.auto else 0
        self.sized_at = 0
        self.base_memory = _anon()   # the server alone, before any site runs
        self.cg = None
        if CGROUP:
            try:
                self.cg = Cgroups(CGROUP, setup=True)
                log.info("per-site cgroups in %s (memory %s, pids %d, cpus %s)", self.cg.own, SITE_MEMORY, SITE_PIDS, SITE_CPUS)
            except OSError as exc:
                if REQUIRE_LIMITS:
                    raise SystemExit("per-site cgroups unavailable (%s); refusing to run sites without their limits "
                                     "(TURBO_REQUIRE_LIMITS=0 to allow rlimits only)" % exc)
                log.error("per-site cgroups unavailable, rlimits only: %s", exc)
        self.tokens, self.tokens_at = max(SPAWN_RATE, 1.0), time.monotonic()
        if LOCK_TMP:   # shared temp dirs: sites may create files there but not list each other's
            for d in ("/tmp", "/var/tmp", "/dev/shm"):
                try:
                    os.chmod(d, 0o1733)
                except OSError:
                    pass
        try:
            with open("/proc/self/oom_score_adj", "w") as fh:
                fh.write("-900")
        except OSError:
            pass               # needs CAP_SYS_RESOURCE; Docker: set oom_score_adj on the container
        self.wake_r, wake_w = os.pipe()
        os.set_blocking(self.wake_r, False)
        os.set_blocking(wake_w, False)
        signal.set_wakeup_fd(wake_w)
        for sig in (signal.SIGCHLD, signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, self._signal)
        self.sel.register(self.wake_r, selectors.EVENT_READ, None)

    def _signal(self, signum, frame):
        self.flags.add(signum)
        if signum in (signal.SIGTERM, signal.SIGINT):
            self.want_stop = True   # kept apart from flags: a loop error must not swallow it

    # sites -------------------------------------------------------------
    def scan(self):
        self.retry_at = 0
        try:
            os.makedirs(SOCKETS, exist_ok=True)
            names = sorted(os.listdir(SITES))
        except OSError as exc:
            log.error("scan: %s", exc)
            self.retry_at = time.monotonic() + 30
            return
        found = set()
        for name in names:
            path = os.path.join(SITES, name)
            try:
                st = os.lstat(path)
            except OSError:
                continue
            if NAME_RE.match(name) and os.path.isdir(path) and not os.path.islink(path) and st.st_uid >= MIN_UID:
                found.add(name)
        for name in sorted(set(self.sites) - found):
            self.remove(name)
        for name in sorted(found - set(self.sites)):
            self.add(name)

    def add(self, name):
        path = os.path.join(SOCKETS, name + ".sock")
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            for p in (path, path + ".new"):
                try:
                    os.unlink(p)
                except FileNotFoundError:
                    pass
            sock.bind(path + ".new")
            if SOCKET_GID >= 0:
                os.chown(path + ".new", 0, SOCKET_GID)
                os.chmod(path + ".new", 0o660)
            else:
                os.chmod(path + ".new", 0o666)
            sock.listen(1024)
            sock.setblocking(False)
            os.rename(path + ".new", path)       # appears for nginx only when it is listening
        except OSError as exc:                   # disk full, ...: this site only, try again later
            sock.close()
            log.error("site %s not added: %s", name, exc)
            self.retry_at = time.monotonic() + 30
            return
        self.sites[name] = {"sock": sock, "pid": None, "started": 0, "fails": 0, "until": 0}
        self.sel.register(sock, selectors.EVENT_READ, name)
        log.info("site %s ready", name)

    def remove(self, name):
        site = self.sites.pop(name)
        if site["pid"]:
            self._kill(site["pid"], signal.SIGTERM)
        else:
            self.sel.unregister(site["sock"])
        if name in self.waiting:
            self.waiting.remove(name)
        try:
            os.unlink(os.path.join(SOCKETS, name + ".sock"))
        except FileNotFoundError:
            pass
        site["sock"].close()
        if self.cg:
            self.cg.drop(name)
        log.info("site %s removed", name)

    # children ----------------------------------------------------------
    def spawn(self, name):
        site = self.sites[name]
        if len(self.children) >= self.max_active:
            if name not in self.waiting:
                self.waiting.append(name)
            self.sel.unregister(site["sock"])
            self._evict()
            return
        if time.monotonic() < site["until"]:
            self._reject(site["sock"])           # crashing site: answer 503 instead of fork-looping
            return
        if not self._spawn_token():
            if name not in self.waiting:
                self.waiting.append(name)        # over TURBO_SPAWN_RATE: wait for the next token
            self.sel.unregister(site["sock"])
            return
        cg = None
        if self.cg:
            try:
                cg = self.cg.site(name)
            except OSError as exc:
                if REQUIRE_LIMITS:
                    self._backoff(name, "not started, its limits failed: %s" % exc)
                    self._reject(site["sock"])
                    return
                log.error("site %s: cgroup: %s (rlimits only)", name, exc)
        self.sel.unregister(site["sock"])
        shared = mmap.mmap(-1, 16)                # last request time (double), requests in flight (int64)
        shared[:16] = struct.pack("dq", 0.0, 0)
        try:
            pid = os.fork()
        except OSError as exc:                   # out of processes or memory: 503 for this site, never die
            shared.close()
            self._backoff(name, "fork failed: %s" % exc)
            self.sel.register(site["sock"], selectors.EVENT_READ, name)
            self._reject(site["sock"])
            return
        if pid == 0:
            code = 0
            fd = site["sock"].fileno()
            for other in self.sites.values():
                other["sock"].detach()           # their fds are closed in serve_site; never close them twice
            try:
                if cg:
                    try:
                        _cg_write(cg, "cgroup.procs", "0")
                    except OSError as exc:
                        sys.stderr.write("site %s: cannot enter its cgroup: %s\n" % (name, exc))
                _limit_self()
                serve_site(name, fd, shared)
            except SystemExit as exc:
                code = exc.code if isinstance(exc.code, int) else 1
                if not isinstance(exc.code, int) and exc.code:
                    sys.stderr.write("%s\n" % exc.code)
            except BaseException:
                logging.getLogger("nexcore_turbo.multisite").exception("site %s failed to start", name)
                code = 1
            finally:
                sys.stderr.flush()
                os._exit(code)
        site.update(pid=pid, started=time.monotonic(), clock=shared, stopping=False)
        self.children[pid] = name

    def _tokens_now(self):
        now = time.monotonic()
        burst = max(SPAWN_RATE, 1.0)
        self.tokens = min(burst, self.tokens + (now - self.tokens_at) * SPAWN_RATE)
        self.tokens_at = now
        return self.tokens

    def _spawn_token(self):
        if SPAWN_RATE <= 0:
            return True
        if self._tokens_now() < 1:
            return False
        self.tokens -= 1
        return True

    def _evict(self):
        """All slots busy: stop the running site that has been idle the longest
        (like an LRU cache) instead of letting new sites wait for TURBO_IDLE."""
        stopping = sum(1 for s in self.sites.values() if s["pid"] and s.get("stopping"))
        if stopping >= len(self.waiting):
            return
        now = time.monotonic()
        idle = []
        for n, s in self.sites.items():
            if not s["pid"] or s.get("stopping"):
                continue
            t, busy = struct.unpack("dq", s["clock"][:16])
            if not t or now - t < 1.0:
                continue                                  # starting (0) or just served
            if busy > 0 and now - t <= SITE_TIMEOUT + BUSY_GRACE:
                continue                                  # a request is still running: never cut it off
            idle.append((t, n))
        if idle:
            name = min(idle)[1]
            self.sites[name]["stopping"] = True
            self._kill(self.sites[name]["pid"], signal.SIGTERM)   # graceful: gunicorn finishes in-flight requests

    def _reject(self, sock):
        while True:
            try:
                conn, _ = sock.accept()
            except (BlockingIOError, InterruptedError):
                return
            try:
                conn.settimeout(0.5)
                conn.sendall(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\nRetry-After: 5\r\n\r\n")
            except OSError:
                pass
            conn.close()

    def _backoff(self, name, why):
        site = self.sites[name]
        site["fails"] += 1
        wait = min(60, 2 ** site["fails"])
        site["until"] = time.monotonic() + wait
        log.warning("site %s %s; backing off %ds", name, why, wait)

    def _kill(self, pid, sig):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            pass

    def reap(self):
        while True:
            try:
                pid, status = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                break
            if pid == 0:
                break
            name = self.children.pop(pid, None)   # gunicorn workers orphaned to PID 1 are reaped too
            site = self.sites.get(name) if name else None
            if site is None or site["pid"] != pid:   # removed (and maybe re-added) while it ran
                continue
            code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -os.WTERMSIG(status)
            ok = code == 0
            lived = time.monotonic() - site["started"]
            if ok or lived > 30 or site.get("stopping"):   # stopped by us: not a crash
                site["fails"] = 0
            else:
                self._backoff(name, "exited with %s after %.1fs" % (code, lived))
            site["pid"] = None
            site["clock"].close()
            self.sel.register(site["sock"], selectors.EVENT_READ, name)
        # free slots go to sites that were kept waiting
        while self.waiting and len(self.children) < self.max_active:
            name = self.waiting.pop(0)
            if name in self.sites and not self.sites[name]["pid"]:
                self.sel.register(self.sites[name]["sock"], selectors.EVENT_READ, name)

    # main loop ---------------------------------------------------------
    def run(self):
        self.scan()
        log.info("serving %d sites (idle %ss, max %s active%s)", len(self.sites), IDLE, "auto" if self.auto else self.max_active,
                 ", memory budget %d MiB" % (self.budget >> 20) if self.auto else "")
        while not self.want_stop:
            try:
                self.step()
            except Exception:                    # one bad site or a full disk must never stop every site
                log.exception("server loop error (continuing)")
                time.sleep(0.2)
        return self.stop()

    def step(self):
        for key, _ in self.sel.select(timeout=1 if self.waiting else 5):
            if key.data is None:
                try:
                    while os.read(self.wake_r, 512):
                        pass
                except BlockingIOError:
                    pass
            elif key.data in self.sites and not self.sites[key.data]["pid"]:
                try:
                    self.spawn(key.data)
                except Exception:
                    log.exception("site %s: spawn failed", key.data)
        flags, self.flags = self.flags, set()
        if signal.SIGCHLD in flags or self.children:
            self.reap()
        if self.waiting and len(self.children) >= self.max_active:
            self._evict()
        # sites kept waiting by TURBO_SPAWN_RATE go back to their sockets as tokens come in
        if self.waiting and len(self.children) < self.max_active:
            room = self.max_active - len(self.children)
            if SPAWN_RATE > 0:
                room = min(room, int(self._tokens_now()))   # their spawns take the tokens
            for name in self.waiting[:room]:
                self.waiting.remove(name)
                if name in self.sites and not self.sites[name]["pid"]:
                    self.sel.register(self.sites[name]["sock"], selectors.EVENT_READ, name)
        if signal.SIGHUP in flags or (self.retry_at and time.monotonic() >= self.retry_at):
            self.scan()
        if self.auto:
            self.resize()

    def resize(self):
        """TURBO_MAX_ACTIVE=auto: as many running sites as the memory budget holds, measured from
        the sites running now (anon + shmem: page cache is reclaimable). With per-site cgroups each
        site is read on its own (pages shared with the server stay charged to the server); without
        them the container's growth since the server started is split over the running sites."""
        now = time.monotonic()
        if now < self.sized_at:
            return
        self.sized_at = now + 5
        running = [name for name in self.children.values() if name in self.sites and not self.sites[name].get("stopping")]
        if len(running) < 3:
            return
        if self.cg:
            per = sum(_anon(os.path.join(self.cg.own, "site-" + name)) for name in running) / len(running)
            base = _anon(os.path.join(self.cg.own, "supervisor"))
        else:
            if not self.base_memory:
                return                               # not in a cgroup namespace: keep the current cap
            per = max(0, _anon() - self.base_memory) / len(running)
            base = self.base_memory
        per = max(per, 8 << 20)
        n = max(2, min(1000, int((self.budget * 0.9 - base) // per)))
        if n != self.max_active:
            log.info("max active sites %d -> %d (%.0f MiB per running site, budget %d MiB)",
                     self.max_active, n, per / 1048576, self.budget >> 20)
            self.max_active = n

    def stop(self):
        for pid in list(self.children):
            self._kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 15
        while self.children and time.monotonic() < deadline:
            try:
                pid, _ = os.waitpid(-1, 0)
            except ChildProcessError:
                break
            self.children.pop(pid, None)
        for name in list(self.sites):
            try:
                os.unlink(os.path.join(SOCKETS, name + ".sock"))
            except FileNotFoundError:
                pass
        return 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    logging.basicConfig(level=logging.INFO, format="[turbo] %(message)s", stream=sys.stderr)
    if argv[:1] == ["serve"]:
        try:   # before any thread: site threads would each get a malloc arena (tens of MiB per site); forks inherit this
            ctypes.CDLL(None).mallopt(-8, 2)   # M_ARENA_MAX
        except (OSError, AttributeError):
            pass
        n = preload(os.environ.get("TURBO_PRELOAD", DEFAULT_PRELOAD), quiet="TURBO_PRELOAD" not in os.environ)
        log.info("preloaded %d modules", n)
        return Server().run()
    if len(argv) >= 3 and argv[0] == "run":
        if CGROUP and NAME_RE.match(argv[1]):   # pip, migrate, shell: inside the site's limits too
            try:
                _cg_write(Cgroups(CGROUP, setup=False).site(argv[1]), "cgroup.procs", "0")
            except OSError as exc:
                log.warning("cgroup: %s", exc)
        _limit_self()
        become(argv[1])
        try:
            os.execvp(argv[2], argv[2:])
        except OSError as exc:
            raise SystemExit("%s: %s" % (argv[2], os.strerror(exc.errno or errno.ENOENT)))
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
