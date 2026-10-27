"""Refresh-on-update for the nginx page cache (see nginx/turbo-http.conf).

    from nexcore_turbo.refresh import refresh
    refresh(["/", post.get_absolute_url()])   # e.g. from a post_save signal

Re-renders each path through nginx with the X-Turbo-Refresh header so the
cached copy is replaced at once. Needs TURBO_REFRESH_URL (where nginx is
reachable, e.g. http://nginx), TURBO_REFRESH_SECRET and TURBO_REFRESH_HOST
(the site's domain) in the environment; does nothing when they are unset.
Runs in a background thread (the process waits for it at exit) and never raises.
"""

import os
import threading
import urllib.request


def _get(base, host, secret, path, scheme):
    req = urllib.request.Request(base.rstrip("/") + path, headers={
        "Host": host, "X-Turbo-Refresh": secret, "X-Forwarded-Proto": scheme})
    try:
        urllib.request.urlopen(req, timeout=10).close()
    except Exception:
        pass


def refresh(paths, wait=False):
    base = os.environ.get("TURBO_REFRESH_URL")
    secret = os.environ.get("TURBO_REFRESH_SECRET")
    host = os.environ.get("TURBO_REFRESH_HOST")
    if not (base and secret and host):
        return None
    unique = list(dict.fromkeys(p for p in paths if p and p.startswith("/")))

    def run():
        for path in unique:
            for scheme in ("https", "http"):   # the cache keeps one copy per forwarded scheme
                _get(base, host, secret, path, scheme)

    # Not a daemon: a management command that saves a post still sends its refresh before exiting.
    thread = threading.Thread(target=run, name="turbo-refresh")
    thread.start()
    if wait:
        thread.join()
    return thread
