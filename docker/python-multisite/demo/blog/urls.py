from django.contrib import admin
from django.urls import path

from blog import views

urlpatterns = [
    path("", views.home, name="home"),
    path("p/<slug:slug>/", views.post, name="post"),
    path("admin/", admin.site.urls),
]
