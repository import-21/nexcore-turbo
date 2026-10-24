import os
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECRET_KEY = "test-only"
DEBUG = False
ALLOWED_HOSTS = ["localhost", "testserver"]
INSTALLED_APPS = [
    "django.contrib.admin", "django.contrib.auth", "django.contrib.contenttypes",
    "django.contrib.sessions", "django.contrib.messages", "django.contrib.staticfiles",
    "django.contrib.humanize", "django.contrib.sitemaps",
]
try:
    import rest_framework  # noqa: F401
    INSTALLED_APPS.append("rest_framework")
except ImportError:
    pass
MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
]
ROOT_URLCONF = "djapp.urls"
TEMPLATES = [{
    "BACKEND": "django.template.backends.django.DjangoTemplates",
    "DIRS": [os.path.join(BASE_DIR, "djapp", "templates")],
    "APP_DIRS": True,
    "OPTIONS": {"context_processors": [
        "django.template.context_processors.request",
        "django.contrib.auth.context_processors.auth",
        "django.contrib.messages.context_processors.messages",
    ]},
}]
WSGI_APPLICATION = "djapp.wsgi.application"
if os.environ.get("PGHOST"):
    DATABASES = {"default": {
        "ENGINE": "django.db.backends.postgresql", "HOST": os.environ["PGHOST"],
        "NAME": "test", "USER": "test", "PASSWORD": "test", "CONN_MAX_AGE": 600,
    }}
else:
    DATABASES = {"default": {"ENGINE": "django.db.backends.sqlite3", "NAME": "/tmp/djapp.sqlite3"}}
STATIC_URL = "/static/"
USE_TZ = True
DEFAULT_AUTO_FIELD = "django.db.models.AutoField"
LOGGING = {"version": 1, "disable_existing_loggers": False,
           "handlers": {"err": {"class": "logging.StreamHandler"}},
           "loggers": {"nexcore_turbo": {"handlers": ["err"], "level": "INFO"}}}
