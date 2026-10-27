#!/bin/sh
# Reproduces the benchmark: official WordPress image vs the nexcore-turbo stack,
# both limited to the same 2 CPUs and 2 GB, 50 virtual users, ROUNDS x 30 s.
#
#   BENCH_CPUS=38,39 K6_CPUS=0-15 ROUNDS=5 bench/run.sh
#
# Pick BENCH_CPUS / K6_CPUS so that the load generator never shares cores with
# the system under test. Results go to bench/results-<date>.txt.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
: "${BENCH_CPUS:=0,1}"
: "${K6_CPUS:=}"
: "${ROUNDS:=5}"
: "${POSTS:=50}"
: "${K6_IMAGE:=grafana/k6:0.54.0}"
export BENCH_CPUS
out="$here/results-$(date +%Y%m%d-%H%M%S).txt"
work=$(mktemp -d)
chmod 755 "$work"   # k6 runs as a non-root user
cp "$here/k6.js" "$work/k6.js"
tc="docker compose -p turbo-bench -f $root/docker/wordpress/compose.yml -f $here/compose.limits.yml"
cleanup() {
    docker compose -f "$here/compose.baseline.yml" down -v >/dev/null 2>&1 || true
    DB_PASSWORD=bench TURBO_REFRESH_SECRET=benchrefresh0123456789 $tc down -v >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

setup_site() { # setup_site <project> <wordpress container> <uid> <url>
    net="$1_default"
    wpcli="docker run --rm --network $net --volumes-from $2 --user $3:$3 -e HOME=/tmp
        -e WORDPRESS_DB_HOST=db -e WORDPRESS_DB_NAME=wordpress -e WORDPRESS_DB_USER=wordpress
        -e WORDPRESS_DB_PASSWORD=bench wordpress:cli wp"
    i=0
    until $wpcli core install --url="$4" --title=Bench --admin_user=admin --admin_password=bench-pass \
            --admin_email=a@example.com --skip-email >/dev/null 2>&1; do
        i=$((i + 1)); [ $i -gt 60 ] && { echo "install failed for $1" >&2; exit 1; }; sleep 3
    done
    $wpcli rewrite structure '/%postname%/' >/dev/null
    $wpcli post generate --count="$POSTS" --post_content="$(seq 1 400 | tr '\n' ' ')" >/dev/null 2>&1 \
        || $wpcli post generate --count="$POSTS" >/dev/null
    { echo /; $wpcli post list --post_type=post --field=url | sed "s#^$4##"; } > "$work/urls.txt"
}

k6() { # k6 <project> <base url> <label>
    docker run --rm ${K6_CPUS:+--cpuset-cpus "$K6_CPUS"} --network "$1_default" -v "$work:/bench:ro" \
        -e BASE="$2" "$K6_IMAGE" run --quiet -e VUS=10 -e DUR=10s /bench/k6.js >/dev/null 2>&1 \
        || { echo "k6 warm-up failed against $2" >&2; exit 1; }
    r=1
    while [ $r -le "$ROUNDS" ]; do
        res=$(docker run --rm ${K6_CPUS:+--cpuset-cpus "$K6_CPUS"} --network "$1_default" -v "$work:/bench:ro" \
            -e BASE="$2" "$K6_IMAGE" run --quiet /bench/k6.js 2>&1)
        rps=$(echo "$res" | awk '/http_reqs/{print $3}' | sed 's#/s##')
        p95=$(echo "$res" | awk '/http_req_duration/{for(i=1;i<=NF;i++) if($i ~ /^p\(95\)=/){sub("p\\(95\\)=","",$i); print $i}}' | head -1)
        okp=$(echo "$res" | awk '/checks/{print $2}')
        printf '%-10s round %d  req/s=%s  p95=%s  ok=%s\n' "$3" "$r" "$rps" "$p95" "$okp" | tee -a "$out"
        r=$((r + 1))
    done
    docker stats --no-stream --format '  {{.Name}} {{.MemUsage}}' $(docker ps -q --filter "label=com.docker.compose.project=$1") | tee -a "$out"
}

{
    echo "nexcore-turbo benchmark $(date -Iseconds)"
    echo "host: $(uname -srm), $(nproc) cpus visible; stack cpus=$BENCH_CPUS k6 cpus=${K6_CPUS:-any}"
    echo "VUs=50, 30s x $ROUNDS rounds, $POSTS posts + home, anonymous GET"
} | tee "$out"

echo "-- baseline (official image)" | tee -a "$out"
docker compose -f "$here/compose.baseline.yml" up -d --quiet-pull >/dev/null 2>&1
setup_site turbo-bench-baseline turbo-bench-baseline-wordpress-1 33 http://wordpress
k6 turbo-bench-baseline http://wordpress baseline
docker compose -f "$here/compose.baseline.yml" down -v >/dev/null 2>&1

echo "-- nexcore-turbo" | tee -a "$out"
DB_PASSWORD=bench TURBO_REFRESH_SECRET=benchrefresh0123456789 $tc up -d --quiet-pull >/dev/null 2>&1
setup_site turbo-bench turbo-bench-wordpress-1 82 http://nginx
k6 turbo-bench http://nginx turbo
echo "saved: $out"
