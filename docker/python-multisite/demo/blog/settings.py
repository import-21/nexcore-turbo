# Demo site for docker/python-multisite: a small blog, configured from turbo.env.
import os

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.environ.get("HOME", BASE_DIR)
SECRET_KEY = os.environ["DJANGO_SECRET_KEY"]
DEBUG = False
ALLOWED_HOSTS = [h for h in os.environ.get("DJANGO_ALLOWED_HOSTS", "localhost").split(",") if h]
INSTALLED_APPS = [
    "django.contrib.admin", "django.contrib.auth", "django.contrib.contenttypes",
    "django.contrib.sessions", "django.contrib.messages", "django.contrib.staticfiles",
    "blog",
]
MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
]
ROOT_URLCONF = "blog.urls"
TEMPLATES = [{
    "BACKEND": "django.template.backends.django.DjangoTemplates",
    "APP_DIRS": True,
    "OPTIONS": {"context_processors": [
        "django.template.context_processors.request",
        "django.contrib.auth.context_processors.auth",
        "django.contrib.messages.context_processors.messages",
    ]},
}]
WSGI_APPLICATION = "blog.wsgi.application"
DATABASES = {"default": {
    "ENGINE": "django.db.backends.sqlite3",
    "NAME": os.path.join(os.environ.get("DJANGO_DATA", HOME), "db.sqlite3"),
}}
STATIC_URL = "/static/"
STATIC_ROOT = os.environ.get("DJANGO_STATIC_ROOT", os.path.join(HOME, "static"))
USE_TZ = True
DEFAULT_AUTO_FIELD = "django.db.models.AutoField"
