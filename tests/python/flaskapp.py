import os
from flask import Flask, jsonify, render_template_string
app = Flask(__name__)
TPL = "<ul>{% for i in items %}<li>{{ i }}</li>{% endfor %}</ul>"

@app.route("/")
def index():
    return render_template_string(TPL, items=range(100))

@app.route("/whoami/")
def whoami():
    return jsonify(pid=os.getpid(), db=0)
