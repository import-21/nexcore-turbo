import random

from django.core.management.base import BaseCommand

from blog.models import Post

WORDS = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore".split()


class Command(BaseCommand):
    help = "Create N demo posts"

    def add_arguments(self, parser):
        parser.add_argument("count", type=int)

    def handle(self, count, **options):
        start = Post.objects.count()
        Post.objects.bulk_create([
            Post(title="Post %d" % n, slug="post-%d" % n,
                 body="\n\n".join(" ".join(random.choices(WORDS, k=60)) for _ in range(4)))
            for n in range(start + 1, start + count + 1)
        ])
