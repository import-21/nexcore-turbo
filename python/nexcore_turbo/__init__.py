"""nexcore-turbo: share one warmed-up copy of a WSGI app across gunicorn workers."""

from nexcore_turbo.cpus import available_cpus
from nexcore_turbo.warmup import warm

__all__ = ["available_cpus", "warm"]
__version__ = "0.1.0"
