import os
from django.contrib import admin
from django.db import connection
from django.http import HttpResponse, JsonResponse
from django.shortcuts import render
from django.urls import path

def page(request):
    return render(request, "page.html", {"title": "turbo", "items": range(200)})

def whoami(request):
    with connection.cursor() as cur:
        if connection.vendor == "postgresql":
            cur.execute("SELECT pg_backend_pid()")
            backend = cur.fetchone()[0]
        else:
            cur.execute("SELECT 1")
            backend = id(connection.connection)
    return JsonResponse({"pid": os.getpid(), "db": backend})

def boom(request):
    raise RuntimeError("warm-up should survive this")

urlpatterns = [
    path("", page),
    path("whoami/", whoami),
    path("boom/", boom),
    path("admin/", admin.site.urls),
]
