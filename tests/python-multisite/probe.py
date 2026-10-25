"""Runs as one site (python -m nexcore_turbo.multisite run <site> python probe.py <other>)
and reports what that site can reach of another site. Prints KEY=VALUE lines."""
import os
import socket
import sys

other = sys.argv[1]
me = os.environ["TURBO_SITE"]


def attempt(fn):
    try:
        fn()
        return "LEAKED"
    except PermissionError:
        return "blocked"
    except OSError as exc:
        return "blocked-%s" % exc.errno


print("uid=%d" % os.getuid())
print("env=" + attempt(lambda: open("/srv/sites/%s/turbo.env" % other).read()))
print("data=" + attempt(lambda: os.listdir("/srv/sites/%s/data" % other)))
print("app=" + attempt(lambda: os.listdir("/srv/sites/%s/app" % other)))
s = socket.socket(socket.AF_UNIX)
print("sock=" + attempt(lambda: s.connect("/run/turbo/%s.sock" % other)))
print("kill1=" + attempt(lambda: os.kill(1, 0)))

# Listening sockets held by this site's own processes: only its own socket may be there.
inodes = {}
with open("/proc/net/unix") as fh:
    for line in fh.read().splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 8 and parts[7].startswith("/run/turbo/"):
            inodes[parts[6]] = parts[7].replace(".sock.new", ".sock")   # bound under a temporary name, then renamed
held = set()
for pid in filter(str.isdigit, os.listdir("/proc")):
    try:
        if os.stat("/proc/" + pid).st_uid != os.getuid():
            continue
        for fd in os.listdir("/proc/%s/fd" % pid):
            link = os.readlink("/proc/%s/fd/%s" % (pid, fd))
            if link.startswith("socket:[") and link[8:-1] in inodes:
                held.add(os.path.basename(inodes[link[8:-1]]))
    except OSError:
        pass
print("held=" + ",".join(sorted(held)))
