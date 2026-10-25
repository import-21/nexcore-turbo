from django.contrib import admin

from blog.models import Post

admin.site.register(Post, prepopulated_fields={"slug": ["title"]})
