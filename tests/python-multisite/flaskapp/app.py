import os

from flask import Flask

app = Flask(__name__)


@app.get("/")
def home():
    return "flask site %s uid=%d" % (os.environ.get("TURBO_SITE"), os.getuid())


@app.get("/echo")
def echo():
    # What the app really received (click ids must never get here), padded past gzip's 1 KB floor.
    from flask import request
    return "<p>uri=%s query=%s compress=%s proto=%s</p>%s" % (
        request.environ.get("RAW_URI", request.full_path), request.query_string.decode(),
        request.headers.get("X-Turbo-Compress", ""), request.headers.get("X-Forwarded-Proto", ""), "<!-- pad -->" * 120)


@app.get("/slow")
def slow():
    # A long request: the site must not be stopped (idle or evicted) while it runs.
    import time
    from flask import request
    time.sleep(float(request.args.get("s", "1")))
    return "slow done"
