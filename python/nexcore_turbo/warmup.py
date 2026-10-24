"""Pre-fork warm-up for WSGI apps under gunicorn.

The idea: load the app once in the gunicorn master, render the pages you list
(so templates, URL resolvers, lazy imports and caches are all built), close
anything that must not be shared across processes (database sockets), then
freeze the garbage collector. Every forked worker then shares that memory
copy-on-write instead of building its own copy.

Works with any WSGI app (Django, Flask, ...). Django database connections are
closed automatically; for other resources use TURBO_AFTER_WARMUP.
"""

import gc
import importlib
import io
import logging
import os
import sys
import time

log = logging.getLogger("nexcore_turbo")


def _env_list(name, default=""):
    raw = os.environ.get(name, default)
    return [p.strip() for p in raw.replace("\n", ",").split(",") if p.strip()]


def paths_from_env():
    paths = _env_list("TURBO_WARMUP_PATHS")
    path_file = os.environ.get("TURBO_WARMUP_FILE")
    if path_file:
        with open(path_file, encoding="utf-8") as fh:
            paths += [line.strip() for line in fh if line.strip() and not line.startswith("#")]
    return paths


def _environ(path, host):
    path, _, query = path.partition("?")
    hostname, _, port = host.partition(":")
    return {
        "REQUEST_METHOD": "GET",
        "SCRIPT_NAME": "",
        "PATH_INFO": path or "/",
        "QUERY_STRING": query,
        "SERVER_NAME": hostname,
        "SERVER_PORT": port or "80",
        "SERVER_PROTOCOL": "HTTP/1.1",
        "HTTP_HOST": host,
        "HTTP_USER_AGENT": "nexcore-turbo-warmup",
        "REMOTE_ADDR": "127.0.0.1",
        "wsgi.version": (1, 0),
        "wsgi.url_scheme": os.environ.get("TURBO_WARMUP_SCHEME", "http"),
        "wsgi.input": io.BytesIO(b""),
        "wsgi.errors": sys.stderr,
        "wsgi.multithread": False,
        "wsgi.multiprocess": True,
        "wsgi.run_once": False,
    }


def request(app, path, host):
    """Call the WSGI app for one GET request; returns the status string."""
    result = {}

    def start_response(status, headers, exc_info=None):
        result["status"] = status
        return lambda data: None

    body = app(_environ(path, host), start_response)
    try:
        for _ in body:
            pass
    finally:
        close = getattr(body, "close", None)
        if close:
            close()
    return result.get("status", "")


def close_shared_resources():
    """Close sockets that would otherwise be inherited by every worker."""
    if "django" in sys.modules:
        try:
            from django.db import connections

            connections.close_all()
        except Exception:  # Django present but not configured
            log.debug("django connections not closed", exc_info=True)
        try:
            from django.core.cache import caches

            caches.close_all()
        except Exception:
            log.debug("django caches not closed", exc_info=True)
    hook = os.environ.get("TURBO_AFTER_WARMUP")
    if hook:
        module, _, func = hook.partition(":")
        getattr(importlib.import_module(module), func or "after_warmup")()


def warm(app, paths=None, host=None, rounds=None, logger=None):
    """Render each path `rounds` times, close shared resources, freeze the GC.

    Never raises: a failing page is logged and skipped so a warm-up problem can
    not stop the server from starting. `logger` defaults to the
    "nexcore_turbo" logger; gunicorn_conf passes gunicorn's own error log.
    """
    out = logger or log
    paths = paths_from_env() if paths is None else paths
    host = host or os.environ.get("TURBO_WARMUP_HOST", "localhost")
    rounds = rounds or int(os.environ.get("TURBO_WARMUP_ROUNDS", "2"))
    started = time.monotonic()
    ok = failed = 0
    for _ in range(rounds):
        for path in paths:
            try:
                status = request(app, path, host)
            except Exception as exc:
                failed += 1
                out.warning("warm-up %s raised %s: %s", path, type(exc).__name__, exc)
                continue
            if status[:1] in ("2", "3"):
                ok += 1
            else:
                failed += 1
                out.warning("warm-up %s returned %s", path, status)
    try:
        close_shared_resources()
    except Exception:
        out.exception("TURBO_AFTER_WARMUP hook failed")
    gc.collect()
    if hasattr(gc, "freeze"):
        gc.freeze()
    out.info(
        "warm-up: %d ok, %d failed, %d paths x %d rounds in %.2fs; gc frozen",
        ok, failed, len(paths), rounds, time.monotonic() - started,
    )
    return ok, failed
