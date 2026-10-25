import os

from flask import Flask

app = Flask(__name__)


@app.get("/")
def home():
    return "flask site %s uid=%d" % (os.environ.get("TURBO_SITE"), os.getuid())
