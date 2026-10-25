from django.db.models import Q
from django.shortcuts import get_object_or_404, render

from blog.models import Post


def home(request):
    q = request.GET.get("s", "").strip()
    posts = Post.objects.all()
    if q:
        posts = posts.filter(Q(title__icontains=q) | Q(body__icontains=q))
    return render(request, "blog/home.html", {"posts": posts[:10], "q": q})


def post(request, slug):
    return render(request, "blog/post.html", {"post": get_object_or_404(Post, slug=slug)})
