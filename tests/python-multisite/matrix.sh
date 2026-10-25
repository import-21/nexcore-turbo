#!/bin/sh
# Runs tests/python-multisite/run.sh for every line of matrix.txt, PARALLEL at a time.
#   PARALLEL=2 tests/python-multisite/matrix.sh [matrix-arm64.txt]
set -u
here=$(cd "$(dirname "$0")" && pwd)
list="${1:-$here/matrix.txt}"
logdir="${LOGDIR:-$here/../../.test-logs/python-multisite}"
mkdir -p "$logdir"
par="${PARALLEL:-2}"
running=0; port=${PORT_BASE:-18500}   # different PORT_BASE for matrices run at the same time
grep -v '^\s*#' "$list" | grep -v '^\s*$' > "$logdir/.list"
while read -r tag dj gun plat; do
    port=$((port + 1))
    name=$(echo "$tag-$dj-$gun-$plat" | tr ':/=*' '____')
    (
        [ "$plat" = - ] && plat=""
        cold=2; idle=4
        [ -n "$plat" ] && { cold=15; idle=20; }   # emulated: forking, importing and docker exec are much slower
        env PYTHON_TAG="$tag" DJANGO="$dj" GUNICORN="$gun" TURBO_IMAGE_TAG="$name" HTTP_PORT=$port COLD_MAX=$cold TEST_IDLE=$idle \
            ${plat:+DOCKER_DEFAULT_PLATFORM=$plat} sh "$here/run.sh" > "$logdir/$name.log" 2>&1
        echo "$? $name"
    ) &
    running=$((running + 1))
    if [ "$running" -ge "$par" ]; then wait; running=0; fi
done < "$logdir/.list"
wait
echo "---- summary"
for f in "$logdir"/*.log; do
    head -2 "$f" | sed -n 's/^== /   /p;s/^   python/      python/p'
    tail -n 30 "$f" | grep -h 'passed,' || echo "   NO RESULT (see $f)"
done
