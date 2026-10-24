#!/bin/sh
# Runs tests/wp/run.sh over a list of stacks, PARALLEL at a time.
#   tests/wp/matrix.sh [matrix-file]     (default: tests/wp/matrix.txt)
# Each line: WORDPRESS_TAG NGINX_VERSION DB_IMAGE [jit] [platform]
set -u
here=$(cd "$(dirname "$0")" && pwd)
list="${1:-$here/matrix.txt}"
logdir="${LOGDIR:-$here/../../.test-logs/wp}"
mkdir -p "$logdir"
par="${PARALLEL:-2}"
port=18100
running=0
grep -v '^\s*#' "$list" | grep -v '^\s*$' > "$logdir/.list"
while read -r wp ng db opt plat; do
    port=$((port + 1))
    name=$(echo "$wp-$ng-$db-$opt-$plat" | tr ':/' '__')
    (
        jit=""; [ "$opt" = jit ] && jit=1
        p=""; [ -n "$plat" ] && p="$plat"; [ "$opt" != jit ] && [ -n "$opt" ] && [ "$opt" != "-" ] && p="$opt"
        WORDPRESS_TAG=$wp NGINX_VERSION=$ng DB_IMAGE=$db HTTP_PORT=$port JIT=$jit PLATFORM=$p \
            sh "$here/run.sh" > "$logdir/$name.log" 2>&1
        echo "$? $name"
    ) &
    running=$((running + 1))
    if [ "$running" -ge "$par" ]; then wait; running=0; fi
done < "$logdir/.list"
wait
echo "---- summary"
grep -h -E '^(\[JIT\] )?wordpress:.*passed' "$logdir"/*.log
! grep -l ' [1-9][0-9]* failed' "$logdir"/*.log
