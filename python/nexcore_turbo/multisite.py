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
    django and gunicorn) once and freezes the GC before forking, so every site
    shares one copy of it copy-on-write.
  * the child drops to the site's uid/gid before it reads anything of the
    site, keeps only its own socket, and loads its app before gunicorn forks
    the worker (see warmup.py).

SIGHUP rescans TURBO_SITES; SIGTERM stops every site and exits.
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
import selectors
import signal
import socket
import struct
import sys
import time

SITES = os.environ.get("TURBO_SITES", "/srv/sites")
SOCKETS = os.environ.get("TURBO_SOCKETS", "/run/turbo")
IDLE = float(os.environ.get("TURBO_IDLE", "10"))
MAX_ACTIVE = int(os.environ.get("TURBO_MAX_ACTIVE", "60"))
MIN_UID = int(os.environ.get("TURBO_MIN_UID", "1000"))
SOCKET_GID = int(os.environ.get("TURBO_SOCKET_GID", "-1"))
SITE_WORKERS = int(os.environ.get("TURBO_SITE_WORKERS", "1"))
# Sync workers by default: they accept one connection at a time, so stopping an
# idle site never drops a connection that was already taken off the queue
# (a gthread worker accepts ahead and would reset those).
SITE_THREADS = int(os.environ.get("TURBO_SITE_THREADS", "1"))
MAX_WORKERS = int(os.environ.get("TURBO_SITE_MAX_WORKERS", "4"))
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,40}$")
# __main__: old gunicorn releases start a server when gunicorn.__main__ is imported.
SKIP_MODULES = re.compile(r"\.(tests?|testing|gis|oracle|mysql|postgresql|__main__)(\.|$)|^django\.contrib\.gis")

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
        "TMPDIR": "/tmp",
        "PYTHONPATH": os.path.join(home, "lib"),
    }
    env.update(_read_env(os.path.join(home, "turbo.env")))   # after setuid: a symlink can't leak root files
    os.environ.clear()
    os.environ.update(env)
    app_dir = os.path.join(home, "app")
    os.chdir(app_dir)
    sys.path[:0] = [app_dir, os.path.join(home, "lib")]
    return home


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
    try:  # setuid made us non-dumpable: let the site's own tools (ps, py-spy) see its processes
        ctypes.CDLL(None).prctl(4, 1, 0, 0, 0)   # PR_SET_DUMPABLE
    except (OSError, AttributeError):
        pass
    from gunicorn.app.base import BaseApplication

    from nexcore_turbo.warmup import close_shared_resources, paths_from_env, warm

    spec = os.environ.get("TURBO_WSGI")
    if not spec:
        raise SystemExit("%s: TURBO_WSGI is not set in turbo.env" % name)
    app = _load(spec)
    paths = paths_from_env()
    if paths:
        warm(app, paths, logger=log)          # also closes DB sockets and freezes the GC
    else:
        close_shared_resources()
        gc.collect()
        gc.freeze()

    last = ctypes.c_double.from_buffer(shared)   # written by the worker(s), read by our master and the server

    def touch(*_):
        last.value = time.monotonic()

    def check_idle(*_):
        if time.monotonic() - last.value > IDLE:
            signal.setitimer(signal.ITIMER_REAL, 0)
            os.kill(os.getpid(), signal.SIGTERM)  # graceful: in-flight requests finish

    def when_ready(server):
        touch()   # 0 until now: the server never stops a site that is still starting
        # A timer in the master only (itimers are not inherited by forked workers).
        signal.signal(signal.SIGALRM, check_idle)
        signal.setitimer(signal.ITIMER_REAL, 1, 1)

    def pre_request(worker, req):
        touch()

    def post_request(worker, req, environ, resp):
        touch()

    workers = max(1, min(int(os.environ.get("TURBO_SITE_WORKERS", SITE_WORKERS)), MAX_WORKERS))
    threads = max(1, min(int(os.environ.get("TURBO_SITE_THREADS", SITE_THREADS)), 16))
    options = {
        "workers": workers,
        "threads": threads,
        "worker_class": "gthread" if threads > 1 else "sync",
        "timeout": int(os.environ.get("TURBO_SITE_TIMEOUT", "30")),
        "graceful_timeout": 10,
        "max_requests": 2000,
        "max_requests_jitter": 200,
        "proc_name": "turbo-" + name,
        "user": os.getuid(),                  # gunicorn's defaults were computed while still root
        "group": os.getgid(),
        "errorlog": "-",
        "loglevel": "warning",
        "when_ready": when_ready,
        "pre_request": pre_request,
        "post_request": post_request,
    }

    class Site(BaseApplication):
        def load_config(self):
            for key, value in options.items():
                self.cfg.set(key, value)

        def load(self):
            return app

    os.environ["LISTEN_FDS"] = "1"            # gunicorn adopts fd 3 and leaves the socket file alone
    os.environ["LISTEN_PID"] = str(os.getpid())
    sys.argv = ["turbo-" + name]
    Site().run()


# ---------------------------------------------------------------- server

def preload(spec):
    """Import the shared framework once; only modules that import without settings stay."""
    before = len(sys.modules)
    for pkg in [p.strip() for p in spec.split(",") if p.strip()]:
        try:
            root = importlib.import_module(pkg)
        except Exception:
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
        self.wake_r, wake_w = os.pipe()
        os.set_blocking(self.wake_r, False)
        os.set_blocking(wake_w, False)
        signal.set_wakeup_fd(wake_w)
        for sig in (signal.SIGCHLD, signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
            signal.signal(sig, self._signal)
        self.sel.register(self.wake_r, selectors.EVENT_READ, None)

    def _signal(self, signum, frame):
        self.flags.add(signum)

    # sites -------------------------------------------------------------
    def scan(self):
        os.makedirs(SOCKETS, exist_ok=True)
        found = set()
        for name in sorted(os.listdir(SITES)):
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
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.bind(path + ".new")
        if SOCKET_GID >= 0:
            os.chown(path + ".new", 0, SOCKET_GID)
            os.chmod(path + ".new", 0o660)
        else:
            os.chmod(path + ".new", 0o666)
        sock.listen(1024)
        sock.setblocking(False)
        os.rename(path + ".new", path)       # appears for nginx only when it is listening
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
        log.info("site %s removed", name)

    # children ----------------------------------------------------------
    def spawn(self, name):
        site = self.sites[name]
        if len(self.children) >= MAX_ACTIVE:
            if name not in self.waiting:
                self.waiting.append(name)
            self.sel.unregister(site["sock"])
            self._evict()
            return
        if time.monotonic() < site["until"]:
            self._reject(site["sock"])           # crashing site: answer 503 instead of fork-looping
            return
        self.sel.unregister(site["sock"])
        shared = mmap.mmap(-1, 8)
        shared[:8] = struct.pack("d", 0.0)
        pid = os.fork()
        if pid == 0:
            code = 0
            fd = site["sock"].fileno()
            for other in self.sites.values():
                other["sock"].detach()           # their fds are closed in serve_site; never close them twice
            try:
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

    def _evict(self):
        """All slots busy: stop the running site that has been idle the longest
        (like an LRU cache) instead of letting new sites wait for TURBO_IDLE."""
        stopping = sum(1 for s in self.sites.values() if s["pid"] and s.get("stopping"))
        if stopping >= len(self.waiting):
            return
        now = time.monotonic()
        idle = [(struct.unpack("d", s["clock"][:8])[0], n) for n, s in self.sites.items()
                if s["pid"] and not s.get("stopping")]
        idle = [(t, n) for t, n in idle if t and now - t >= 1.0]   # not starting (0), not serving right now
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
            if site is None:
                continue
            code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -os.WTERMSIG(status)
            ok = code == 0
            lived = time.monotonic() - site["started"]
            if ok or lived > 30 or site.get("stopping"):   # stopped by us: not a crash
                site["fails"] = 0
            else:
                site["fails"] += 1
                site["until"] = time.monotonic() + min(60, 2 ** site["fails"])
                log.warning("site %s exited with %s after %.1fs; backing off %ds", name,
                            code, lived, min(60, 2 ** site["fails"]))
            site["pid"] = None
            site["clock"].close()
            self.sel.register(site["sock"], selectors.EVENT_READ, name)
        # free slots go to sites that were kept waiting
        while self.waiting and len(self.children) < MAX_ACTIVE:
            name = self.waiting.pop(0)
            if name in self.sites and not self.sites[name]["pid"]:
                self.sel.register(self.sites[name]["sock"], selectors.EVENT_READ, name)

    # main loop ---------------------------------------------------------
    def run(self):
        self.scan()
        log.info("serving %d sites (idle %ss, max %d active)", len(self.sites), IDLE, MAX_ACTIVE)
        while True:
            for key, _ in self.sel.select(timeout=1 if self.waiting else 5):
                if key.data is None:
                    try:
                        while os.read(self.wake_r, 512):
                            pass
                    except BlockingIOError:
                        pass
                elif key.data in self.sites and not self.sites[key.data]["pid"]:
                    self.spawn(key.data)
            flags, self.flags = self.flags, set()
            if signal.SIGCHLD in flags or self.children:
                self.reap()
            if self.waiting and len(self.children) >= MAX_ACTIVE:
                self._evict()
            if signal.SIGHUP in flags:
                self.scan()
            if flags & {signal.SIGTERM, signal.SIGINT}:
                return self.stop()

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
        n = preload(os.environ.get("TURBO_PRELOAD", "django,gunicorn"))
        log.info("preloaded %d modules", n)
        return Server().run()
    if len(argv) >= 3 and argv[0] == "run":
        become(argv[1])
        try:
            os.execvp(argv[2], argv[2:])
        except OSError as exc:
            raise SystemExit("%s: %s" % (argv[2], os.strerror(exc.errno or errno.ENOENT)))
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
