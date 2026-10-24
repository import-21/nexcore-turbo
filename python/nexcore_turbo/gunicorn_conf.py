"""Ready-made gunicorn config:  gunicorn -c python:nexcore_turbo.gunicorn_conf myproject.wsgi

Or extend it from your own config file:

    from nexcore_turbo.gunicorn_conf import *   # noqa
    bind = "unix:/run/app.sock"

Environment variables:
    TURBO_BIND            default 0.0.0.0:8000
    TURBO_WORKERS         default: CPUs available to this process/container
    TURBO_WARMUP_PATHS    comma separated GET paths rendered before forking
    TURBO_WARMUP_FILE     file with one path per line
    TURBO_WARMUP_HOST     Host header for warm-up requests (must be in ALLOWED_HOSTS)
    TURBO_WARMUP_ROUNDS   default 2
    TURBO_AFTER_WARMUP    "module:function" to close your own pools/sockets
    TURBO_DISABLE         set to 1 to fall back to plain gunicorn behaviour
"""

import os

from nexcore_turbo.cpus import available_cpus

_enabled = os.environ.get("TURBO_DISABLE", "") not in ("1", "true", "yes")

bind = os.environ.get("TURBO_BIND", "0.0.0.0:8000")
workers = int(os.environ.get("TURBO_WORKERS") or available_cpus())
preload_app = _enabled
max_requests = int(os.environ.get("TURBO_MAX_REQUESTS", "0"))
max_requests_jitter = max_requests // 10


def when_ready(server):
    # Runs in the master after the app is loaded and before any worker forks.
    if not _enabled:
        return
    from nexcore_turbo.warmup import warm

    warm(server.app.wsgi(), logger=server.log)
