# nexcore-turbo (Python)

- `nexcore_turbo.gunicorn_conf`: gunicorn config that renders your pages once
  before forking so every worker shares the warmed-up app.
- `nexcore_turbo.multisite`: many small WSGI sites on one server; idle sites
  stop, running ones share one preloaded copy of the framework, the number
  running at once follows a memory budget, per-site cgroup v2 limits when
  enabled, and cacheable pages are gzipped once so nginx caches them
  compressed (`docker/python-multisite`).
- `nexcore_turbo.refresh`: refresh-on-update for the nginx page cache.

See the main README of nexcore-turbo for usage.
