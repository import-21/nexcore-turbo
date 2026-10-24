#!/bin/sh
# Runs tests/python/run.sh for every line of matrix.txt, PARALLEL at a time.
set -u
here=$(cd "$(dirname "$0")" && pwd)
list="${1:-$here/matrix.txt}"
logdir="${LOGDIR:-$here/../../.test-logs/python}"
mkdir -p "$logdir"
par="${PARALLEL:-2}"
running=0
grep -v '^\s*#' "$list" | grep -v '^\s*$' > "$logdir/.list"
while read -r img kind gun fw pg cpu plat; do
    name=$(echo "$img-$kind-$gun-$fw-$pg-$cpu-$plat" | tr ':/=*' '____')
    (
        [ "$pg" = - ] && pg=""; [ "$plat" = - ] && plat=""
        cpus=""; expect=""
        [ "$cpu" != - ] && { cpus=${cpu%/*}; expect=${cpu#*/}; }
        if [ "$kind" = django ]; then fwvar="DJANGO=$fw"; else fwvar="FLASK=$fw"; fi
        env IMAGE="$img" KIND="$kind" GUNICORN="$gun" "$fwvar" PG="$pg" CPUS="$cpus" EXPECT_CPUS="$expect" \
            PLATFORM="$plat" sh "$here/run.sh" > "$logdir/$name.log" 2>&1
        echo "$? $name"
    ) &
    running=$((running + 1))
    if [ "$running" -ge "$par" ]; then wait; running=0; fi
done < "$logdir/.list"
wait
echo "---- summary"
for f in "$logdir"/*.log; do
    head -1 "$f" | sed 's/^== /   /'
    grep -h '^RESULT' "$f" || echo "   NO RESULT (see $f)"
done
! grep -L '^RESULT.* 0 failed' "$logdir"/*.log | grep .
