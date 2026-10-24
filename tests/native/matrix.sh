#!/bin/sh
# tests/native/matrix.sh [image ...]   PARALLEL at a time (default 2)
set -u
here=$(cd "$(dirname "$0")" && pwd)
logdir="${LOGDIR:-$here/../../.test-logs/native}"
mkdir -p "$logdir"
imgs="${*:-ubuntu:22.04 ubuntu:24.04 debian:12 debian:13 rockylinux:8 rockylinux:9 almalinux:10 amazonlinux:2023 fedora:42 alpine:3.20 alpine:3.22}"
par="${PARALLEL:-2}"; n=0
for img in $imgs; do
    ( sh "$here/run.sh" "$img" > "$logdir/$(echo "$img" | tr ':/' '__').log" 2>&1; echo "$? $img" ) &
    n=$((n + 1)); [ $n -ge "$par" ] && { wait; n=0; }
done
wait
echo "---- summary"
for f in "$logdir"/*.log; do
    grep -h -E '^native .*passed' "$f" || echo "NO RESULT: $f (exit before tests: $(tail -2 "$f" | tr '\n' ' '))"
done
! grep -L ' 0 failed' "$logdir"/*.log | grep .
