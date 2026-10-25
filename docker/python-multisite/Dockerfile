# nexcore-turbo python multi-site: one preloaded server that runs every site on demand.
# Build context: the repository root (see compose.yml).
ARG PYTHON_TAG=3.12-slim
FROM python:${PYTHON_TAG}
ARG DJANGO="django==5.2.*"
ARG GUNICORN="gunicorn==23.*"
ARG EXTRA=""
RUN if command -v apk >/dev/null; then apk add --no-cache procps >/dev/null; \
    else apt-get update -qq && apt-get install -y -qq --no-install-recommends procps >/dev/null && rm -rf /var/lib/apt/lists/*; fi
RUN pip install --no-cache-dir --root-user-action=ignore --disable-pip-version-check "$DJANGO" "$GUNICORN" $EXTRA
COPY python /tmp/nexcore-turbo
RUN pip install --no-cache-dir --root-user-action=ignore --disable-pip-version-check /tmp/nexcore-turbo \
    && rm -rf /tmp/nexcore-turbo
COPY docker/python-multisite/demo /opt/turbo-demo
CMD ["python", "-m", "nexcore_turbo.multisite", "serve"]
