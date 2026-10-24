#!/bin/sh
# Runs check.py inside a throw-away python container.
#   IMAGE=python:3.12-slim DJANGO="django==5.2.*" GUNICORN="gunicorn==23.*" KIND=django PG=1 tests/python/run.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
: "${IMAGE:=python:3.12-slim}"
: "${KIND:=django}"
: "${GUNICORN:=gunicorn}"
: "${DJANGO:=django}"
: "${FLASK:=flask}"
: "${EXTRA:=djangorestframework}"
: "${PG:=}"
: "${PLATFORM:=}"
: "${CPUS:=}"
tag=$(echo "$IMAGE$KIND$GUNICORN$DJANGO$PG$PLATFORM$$" | cksum | cut -c1-8)
net="turbopy$tag"

cleanup() {
    docker rm -f "pg$tag" >/dev/null 2>&1
    docker network rm "$net" >/dev/null 2>&1
}
trap cleanup EXIT INT TERM
docker network create "$net" >/dev/null

pgenv=""
if [ -n "$PG" ]; then
    docker run -d --name "pg$tag" --network "$net" -e POSTGRES_PASSWORD=test -e POSTGRES_USER=test \
        -e POSTGRES_DB=test postgres:16-alpine >/dev/null
    pgenv="-e PGHOST=pg$tag"
fi

if [ "$KIND" = django ]; then
    pkgs="$GUNICORN $DJANGO $EXTRA"
    [ -n "$PG" ] && pkgs="$pkgs psycopg2-binary"
else
    pkgs="$GUNICORN $FLASK"
fi

echo "== $IMAGE ${PLATFORM:-native} $KIND [$pkgs]${PG:+ +postgres}${CPUS:+ cpus=$CPUS}"
# shellcheck disable=SC2086
docker run --rm ${PLATFORM:+--platform "$PLATFORM"} ${CPUS:+--cpus "$CPUS"} ${EXPECT_CPUS:+-e EXPECT_CPUS="$EXPECT_CPUS"} --network "$net" $pgenv \
    -v "$root:/src:ro" -w /work "$IMAGE" sh -c '
    set -e
    cp -r /src/tests/python/. /work/ && cp -r /src/python /tmp/pkg
    command -v ps >/dev/null || { (apt-get update -qq && apt-get install -y -qq procps) >/dev/null 2>&1 || apk add -q procps >/dev/null 2>&1 || true; }
    pip install -q --disable-pip-version-check --root-user-action=ignore '"$pkgs"' /tmp/pkg 2>&1 | grep -v "^\[notice\]" || true
    if [ -n "'"$PG"'" ]; then
        python - <<PY
import time, psycopg2
for _ in range(60):
    try:
        psycopg2.connect(host="'"pg$tag"'", user="test", password="test", dbname="test").close(); break
    except Exception: time.sleep(1)
PY
    fi
    python -c "import gunicorn, nexcore_turbo, sys; print(\"   gunicorn\", gunicorn.__version__, \"cpus\", nexcore_turbo.available_cpus())"
    [ "'"$KIND"'" = django ] && python -c "import django; print(\"   django\", django.get_version())"
    python check.py '"$KIND"'
'
