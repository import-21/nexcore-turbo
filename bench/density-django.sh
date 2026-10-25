#!/bin/sh
# How many Django sites fit on 2 CPUs and 2 GB?  (the WordPress version is density.sh)
#
#   MODE=baseline STEPS="10 15 20 25"   bench/density-django.sh   # one container per site: gunicorn -w 2
#   MODE=turbo    STEPS="50 100 200"    bench/density-django.sh   # docker/python-multisite
#
# Same traffic, pass criteria and output as density.sh. Every site is the demo
# blog (docker/python-multisite/demo) with SQLite, so there is no database
# container on either side.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
: "${MODE:=turbo}"
: "${STEPS:=10 25 50}"
: "${RATE_PER_SITE:=0.5}"
: "${UNCACHED:=0.1}"
: "${POSTS:=10}"
: "${DUR:=60s}"
: "${WARM:=60s}"
: "${P95_MS:=500}"
: "${MEM_BUDGET_MB:=2048}"
: "${BENCH_CPUS:=0,1}"
: "${K6_CPUS:=}"
: "${K6_IMAGE:=grafana/k6:0.54.0}"
: "${BASELINE_WORKERS:=2}"
export BENCH_CPUS
out="$here/density-django-$MODE-$(date +%Y%m%d-%H%M%S)-$$.txt"
work=$(mktemp -d); chmod 777 "$work"; cp "$here/density.js" "$work/"
: "${PROJECT:=turbo-density-dj}"   # must not start with tdj- (baseline container prefix)
project=$PROJECT
dc="docker compose -p $project -f $root/docker/python-multisite/compose.yml -f $here/compose.density-django.yml"
image=nexcore-turbo-python:3.12-slim
net_base=tdj-base

cleanup() {
    [ "${KEEP:-0}" = 1 ] && { echo "KEEP=1: leaving the stack running; k6 files in $work"; return; }
    if [ "$MODE" = turbo ]; then $dc down -v >/dev/null 2>&1 || true
    else
        docker ps -aq --filter name=tdj- | xargs -r docker rm -f >/dev/null 2>&1 || true
        docker network rm $net_base >/dev/null 2>&1 || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

log() { echo "$*" | tee -a "$out"; }
site() { printf 'site%03d' "$1"; }
containers() {
    if [ "$MODE" = turbo ]; then docker ps -q --filter label=com.docker.compose.project=$project
    else docker ps -q --filter name=tdj-; fi
}
mem_total() {
    docker stats --no-stream --format '{{.MemUsage}}' $(containers) | awk '{
        v = $1; u = v; gsub(/[0-9.]/, "", u); n = v + 0
        if (u == "GiB") n *= 1024; else if (u == "KiB" || u == "kB") n /= 1024; else if (u == "B") n /= 1048576
        t += n } END { printf "%.0f", t }'
}
cpu_total() {
    docker stats --no-stream --format '{{.CPUPerc}}' $(containers) | tr -d '%' | awk '{t += $1} END {printf "%.0f", t}'
}

# ---------- setup ----------
$dc build -q app >/dev/null   # $image: also used for the baseline sites
if [ "$MODE" = turbo ]; then
    $dc up -d --quiet-pull >/dev/null 2>&1
    net=${project}_default
else
    docker network create $net_base >/dev/null
    net=$net_base
fi

added=0
add_sites_to() {
    while [ $added -lt "$1" ]; do
        added=$((added + 1)); s=$(site $added)
        if [ "$MODE" = turbo ]; then
            COMPOSE_PROJECT_NAME=$project sh "$root/docker/python-multisite/add-site.sh" "$s" --domain test \
                --posts "$POSTS" --no-reload >/dev/null
        else
            # The usual way: the project in its own container, gunicorn with a few workers.
            docker run -d --name "tdj-$s" --network $net_base --network-alias "$s" --cpuset-cpus "$BENCH_CPUS" \
                -e DJANGO_SECRET_KEY="bench-$s-$$" -e DJANGO_ALLOWED_HOSTS="$s" -e HOME=/site -w /site \
                "$image" sh -c "cp -a /opt/turbo-demo/. /site/ && python manage.py migrate -v0 --noinput \
                    && python manage.py seed $POSTS && exec gunicorn -w $BASELINE_WORKERS -b 0.0.0.0:8000 blog.wsgi" >/dev/null
        fi
    done
    if [ "$MODE" = turbo ]; then
        docker exec ${project}-app-1 sh -c 'kill -HUP 1'
        docker exec ${project}-nginx-1 nginx -s reload >/dev/null 2>&1
        j=0; until docker exec ${project}-app-1 test -S "/run/turbo/$(site $added).sock"; do
            j=$((j + 1)); [ $j -gt 100 ] && { echo "sites did not load" >&2; exit 1; }; sleep 0.3
        done
    else
        j=0; until docker run --rm --network $net_base curlimages/curl:8.10.1 -sf -o /dev/null "http://$(site $added):8000/"; do
            j=$((j + 1)); [ $j -gt 60 ] && { echo "baseline site did not start" >&2; exit 1; }; sleep 2
        done
    fi
}

write_targets() {
    {
        printf '['
        k=1
        while [ $k -le $added ]; do
            s=$(site $k)
            if [ "$MODE" = turbo ]; then base=http://nginx; host="$s.test"; else base="http://$s:8000"; host=""; fi
            paths=$(awk -v n="$POSTS" 'BEGIN{printf "\"/\""; for (i = 1; i <= n; i++) printf ",\"/p/post-%d/\"", i}')
            printf '%s{"base":"%s","host":"%s","paths":[%s]}' "$( [ $k -gt 1 ] && echo ,)" "$base" "$host" "$paths"
            k=$((k + 1))
        done
        printf ']'
    } > "$work/sites.json"
}

log "nexcore-turbo Django density benchmark $(date -Iseconds)  mode=$MODE"
log "host: $(uname -srm), cpus=$BENCH_CPUS (k6: ${K6_CPUS:-any}), budget ${MEM_BUDGET_MB} MiB, p95 <= ${P95_MS} ms"
log "load: $RATE_PER_SITE visits/s per site, $(awk "BEGIN{print $UNCACHED*100}")% uncached searches, $WARM warm-up then $DUR measured per step, $POSTS posts per site$( [ "$MODE" = baseline ] && echo ", gunicorn -w $BASELINE_WORKERS per site")"
log "sites  rate/s  p95(ms)  p95-uncached(ms)  errors  mem(MiB)  cpu(%)  idle-mem(MiB)  result  notes"

crawled=0
crawl_new_sites() { # view every page of newly added sites once, like a site that has been online for a while (as density.sh)
    python3 - "$work/sites.json" "$crawled" > "$work/crawl.txt" <<'PY'
import json, sys
for s in json.load(open(sys.argv[1]))[int(sys.argv[2]):]:
    for p in s["paths"]:
        print((s["host"] or "-") + " " + s["base"] + p)
PY
    docker run --rm ${K6_CPUS:+--cpuset-cpus "$K6_CPUS"} --network "$net" -v "$work:/bench:ro" --entrypoint sh \
        curlimages/curl:8.10.1 -c 'xargs -P 2 -n 2 sh -c '"'"'if [ "$0" = - ]; then curl -s -o /dev/null -m 30 "$1"; else curl -s -o /dev/null -m 30 -H "Host: $0" "$1"; fi'"'"' < /bench/crawl.txt'
    crawled=$added
}

for n in $STEPS; do
    add_sites_to "$n"
    write_targets
    crawl_new_sites
    sleep 15
    idle=$(mem_total)
    rate=$(awk "BEGIN{r=$n*$RATE_PER_SITE; printf \"%d\", (r<1?1:r+0.5)}")
    docker run --rm ${K6_CPUS:+--cpuset-cpus "$K6_CPUS"} --network "$net" -v "$work:/bench" -e RATE="$rate" \
        -e UNCACHED="$UNCACHED" -e DUR="$WARM" "$K6_IMAGE" run --quiet /bench/density.js >/dev/null 2>&1 || true
    ( sleep $(( ${DUR%s} * 2 / 3 )); mem_total > "$work/mem"; cpu_total > "$work/cpu"
      if [ "$MODE" = turbo ]; then
          docker exec ${project}-app-1 sh -c 'ps -eo uid= | awk "\$1>=20000" | sort -u | wc -l' > "$work/active"
      fi ) &
    sampler=$!
    docker run --rm ${K6_CPUS:+--cpuset-cpus "$K6_CPUS"} --network "$net" -v "$work:/bench" -e RATE="$rate" \
        -e UNCACHED="$UNCACHED" -e DUR="$DUR" "$K6_IMAGE" run --quiet --summary-export=/bench/summary.json \
        /bench/density.js >/dev/null 2>&1 || true
    wait $sampler || true
    [ -f "$work/summary.json" ] || { log "k6 produced no summary at $n sites"; exit 1; }
    read -r p95 p95u err <<EOM
$(python3 - "$work/summary.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))["metrics"]
d = m["http_req_duration"]; u = m.get("http_req_duration{kind:uncached}", {})
print(round(d["p(95)"]), round(u.get("p(95)", 0)), m["checks"].get("fails", 0) + 0)
PY
)
EOM
    rm -f "$work/summary.json"
    mem=$(cat "$work/mem"); cpu=$(cat "$work/cpu")
    res=PASS
    [ "$err" -gt 0 ] && res="FAIL(errors)"
    [ "$p95" -gt "$P95_MS" ] && res="FAIL(p95)"
    [ "$mem" -gt "$MEM_BUDGET_MB" ] && res="FAIL(memory)"
    notes=""
    if [ "$MODE" = turbo ]; then
        bad=$(docker logs --since 70s ${project}-nginx-1 2>/dev/null | awk '$9 ~ /^[0-9]+$/ && $9 != 200 {print $9" "$7}' | sort | uniq -c | sort -rn | head -3 | tr '\n' ';')
        warn=$(docker logs --since 130s ${project}-app-1 2>&1 | grep -vE "site .* ready|preloaded|serving " | sed -E 's/^\[[^]]*\] //' | sort | uniq -c | sort -rn | head -3 | tr '\n' ';')
        notes="active-sites=$(cat "$work/active") non200=[$bad] app=[$warn]"
    fi
    printf '%5s  %6s  %7s  %16s  %6s  %8s  %6s  %13s  %s  %s\n' "$n" "$rate" "$p95" "$p95u" "$err" "$mem" "$cpu" "$idle" "$res" "$notes" | tee -a "$out"
    [ "$res" = PASS ] || [ "${CONTINUE:-0}" = 1 ] || break
done
log "saved: $out"
