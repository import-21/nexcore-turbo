from django.db import models
from django.db.models.signals import post_delete, post_save
from django.dispatch import receiver
from django.urls import reverse


class Post(models.Model):
    title = models.CharField(max_length=200)
    slug = models.SlugField(unique=True)
    body = models.TextField()
    published = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-published", "-id"]

    def __str__(self):
        return self.title

    def get_absolute_url(self):
        return reverse("post", args=[self.slug])


@receiver([post_save, post_delete], sender=Post)
def refresh_pages(sender, instance, **kwargs):
    # Refresh-on-update: re-render the cached copies that show this post.
    try:
        from nexcore_turbo.refresh import refresh
    except ImportError:
        return
    refresh(["/", instance.get_absolute_url()])
