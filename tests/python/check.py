"""Behaviour checks for nexcore_turbo under a real gunicorn. Linux only, stdlib only.

    python check.py django|flask

Expects gunicorn, the app's framework and nexcore_turbo to be installed, and
the current directory to contain the test apps.
"""

import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

KIND = sys.argv[1]
WORKERS = 4
RESULTS = []
PORT = 18765


def ok(name, cond, detail=""):
    RESULTS.append((name, bool(cond), detail))
    print("  %s %s%s" % ("ok  " if cond else "FAIL", name, ("  (" + str(detail) + ")") if detail != "" else ""), flush=True)


def get(path, timeout=10):
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (PORT, path), headers={"Host": "localhost"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def children(pid):
    try:
        with open("/proc/%d/task/%d/children" % (pid, pid)) as fh:
            return [int(p) for p in fh.read().split()]
    except OSError:
        out = subprocess.run(["ps", "-o", "pid=", "--ppid", str(pid)], capture_output=True, text=True).stdout
        return [int(p) for p in out.split()]


def private_kb(pid):
    total = 0
    with open("/proc/%d/smaps_rollup" % pid) as fh:
        for line in fh:
            if line.startswith(("Private_Clean:", "Private_Dirty:")):
                total += int(line.split()[1])
    return total


class Server:
    def __init__(self, env_extra, app):
        self.log = tempfile.NamedTemporaryFile("w+", delete=False, suffix=".log")
        env = dict(os.environ, TURBO_BIND="127.0.0.1:%d" % PORT, TURBO_WORKERS=str(WORKERS), **env_extra)
        self.proc = subprocess.Popen(
            [sys.executable, "-m", "gunicorn", "-c", "python:nexcore_turbo.gunicorn_conf", app],
            env=env, stdout=self.log, stderr=subprocess.STDOUT,
        )

    def wait_ready(self, timeout=90):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc.poll() is not None:
                return False
            try:
                if get("/whoami/", timeout=2)[0] == 200 and len(children(self.proc.pid)) >= WORKERS:
                    return True
            except Exception:
                pass
            time.sleep(0.3)
        return False

    def output(self):
        self.log.flush()
        with open(self.log.name) as fh:
            return fh.read()

    def stop(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(20)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()


APP = "djapp.wsgi" if KIND == "django" else "flaskapp:app"
PAGES = "/,/admin/login/" if KIND == "django" else "/"
if KIND == "django":
    sys.path.insert(0, os.path.join(os.getcwd(), "djapp"))
    os.environ["PYTHONPATH"] = os.pathsep.join([os.path.join(os.getcwd(), "djapp"), os.getcwd()])
    subprocess.run([sys.executable, "djapp/manage.py", "migrate", "--noinput"], check=True,
                   stdout=subprocess.DEVNULL)
else:
    os.environ["PYTHONPATH"] = os.getcwd()


def exercise():
    # Touch every page enough times that each worker has rendered all of them.
    paths = PAGES.split(",")
    for _ in range(WORKERS * 15):
        for p in paths:
            get(p)


def measure(srv):
    exercise()
    time.sleep(0.5)
    kids = children(srv.proc.pid)
    vals = sorted(private_kb(p) for p in kids)
    return vals[len(vals) // 2], vals


print("== %s / python %s" % (KIND, sys.version.split()[0]))
if os.environ.get("EXPECT_CPUS"):
    from nexcore_turbo import available_cpus
    ok("available_cpus honours the container CPU limit", str(available_cpus()) == os.environ["EXPECT_CPUS"],
       available_cpus())

# 1. Turbo on: warm-up, hook, sharing, correctness.
try:
    os.unlink("/tmp/turbo-hook-ran")
except OSError:
    pass
on = Server({"TURBO_WARMUP_PATHS": PAGES + ",/boom/,/does-not-exist/",
             "TURBO_AFTER_WARMUP": "hooks:after_warmup"}, APP)
ready = on.wait_ready()
ok("server starts with turbo (and failing warm-up pages)", ready, "" if ready else on.output()[-1500:])
if not ready:
    on.stop()
    sys.exit(1)
out = on.output()
ok("warm-up log line", "warm-up:" in out and "gc frozen" in out)
expected_ok = len(PAGES.split(",")) * 2
ok("warm-up rendered the listed pages", ("warm-up: %d ok" % expected_ok) in out, [l for l in out.splitlines() if "warm-up:" in l])
ok("broken warm-up pages logged, not fatal", KIND == "flask" or "/boom/ " in out)
ok("TURBO_AFTER_WARMUP hook ran in master", os.path.exists("/tmp/turbo-hook-ran")
   and open("/tmp/turbo-hook-ran").read() == str(on.proc.pid))

seen = {}
errors = []


def hammer():
    for _ in range(60):
        try:
            code, body = get("/whoami/")
            if code != 200:
                errors.append(code)
                continue
            d = json.loads(body)
            seen.setdefault(d["pid"], set()).add(d["db"])
        except Exception as e:  # noqa: BLE001
            errors.append(repr(e))


threads = [threading.Thread(target=hammer) for _ in range(8)]
for t in threads:
    t.start()
for t in threads:
    t.join()
ok("480 concurrent requests, no errors", not errors, errors[:3])
# Which worker accepts is up to the kernel; keep asking before calling one idle.
for _ in range(1500):
    if len(seen) >= WORKERS:
        break
    code, body = get("/whoami/")
    if code == 200:
        d = json.loads(body)
        seen.setdefault(d["pid"], set()).add(d["db"])
ok("all %d workers served traffic" % WORKERS, len(seen) == WORKERS, sorted(seen))
if KIND == "django" and os.environ.get("PGHOST"):
    # SQLite closes its connection after every request, so only PostgreSQL
    # (persistent connections, CONN_MAX_AGE) can show sharing.
    backends = [next(iter(v)) for v in seen.values() if len(v) == 1]
    ok("each worker keeps one DB connection", all(len(v) == 1 for v in seen.values()), {k: list(v) for k, v in seen.items()})
    ok("no DB connection shared between workers", len(set(backends)) == len(backends), backends)

code, body = get("/")
ok("page renders correctly", code == 200 and (b"turbo" in body or b"<li>" in body), code)
med_on, all_on = measure(on)

# HUP reload: new workers come up and serve.
old = set(children(on.proc.pid))
on.proc.send_signal(signal.SIGHUP)
deadline = time.time() + 30
new = set()
while time.time() < deadline:
    new = set(children(on.proc.pid))
    if len(new) >= WORKERS and not (new & old):
        break
    time.sleep(0.3)
ok("SIGHUP replaces workers", len(new) >= WORKERS and not (new & old), (sorted(old), sorted(new)))
ok("serves after reload", get("/whoami/")[0] == 200)
on.stop()
ok("clean shutdown", on.proc.returncode == 0, on.proc.returncode)

# 2. Turbo off: same app, same load, for comparison.
off = Server({"TURBO_DISABLE": "1"}, APP)
ok("server starts with TURBO_DISABLE=1", off.wait_ready())
med_off, all_off = measure(off)
off.stop()

saving = 1 - med_on / med_off if med_off else 0
print("  info private memory per worker (median kB): turbo=%d plain=%d  -> %.0f%% less" % (med_on, med_off, saving * 100))
print("  info turbo workers %s / plain workers %s" % (all_on, all_off))
ok("workers use less private memory with turbo", med_on < med_off * 0.8, "%.0f%%" % (saving * 100))

failed = [r for r in RESULTS if not r[1]]
print("RESULT %s python%s: %d passed, %d failed, memory saving %.0f%% (%d -> %d kB)" % (
    KIND, sys.version.split()[0], len(RESULTS) - len(failed), len(failed), saving * 100, med_off, med_on))
sys.exit(1 if failed else 0)
