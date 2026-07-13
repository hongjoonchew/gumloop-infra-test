import os
import random
import time

from flask import Flask, abort, jsonify
from prometheus_flask_exporter import PrometheusMetrics
from werkzeug.exceptions import HTTPException

APP_VERSION = os.environ.get("APP_VERSION", "0.1.0")

app = Flask(__name__)

metrics = PrometheusMetrics(app, defaults_prefix="flask")
metrics.info("app_info", "Application info", version=APP_VERSION)


@app.route("/", methods=["GET"])
def root():
    """Health-check endpoint expected by probes/tests."""
    return jsonify(status="ok"), 200


@app.errorhandler(HTTPException)
def handle_http_exception(exc: HTTPException):
    return jsonify(error=exc.name, code=exc.code), exc.code


if __name__ == "__main__":
    # Local dev runner: `python app/main.py`
    app.run(host="0.0.0.0", port=8080, debug=True)
