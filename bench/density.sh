#!/bin/sh
# How many WordPress sites fit on 2 CPUs and 2 GB?
#
#   MODE=baseline STEPS="1 2 4 6 8"      bench/density.sh   # one official container per site
#   MODE=turbo    STEPS="25 50 100 200"  bench/density.sh   # docker/multisite
#
# For each step the sites receive RATE_PER_SITE visits per second in total
# (UNCACHED of them are searches that always run PHP + SQL) for DUR. A step
# passes when there are no errors, p95 <= P95_MS and the memory of every
# container in the run (web + PHP + database) stays <= MEM_BUDGET_MB.
# Sites are added incrementally; the run stops at the first failing step.
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
: "${WORDPRESS_TAG:=php8.3-fpm-alpine}"
: "${BASELINE_TAG:=php8.3-apache}"
export BENCH_CPUS
out="$here/density-$MODE-$(date +%Y%m%d-%H%M%S).txt"
work=$(mktemp -d); chmod 777 "$work"; cp "$here/density.js" "$work/"   # k6 (non-root) writes its summary here
dbpass=bench-root
turbo_dc="docker compose -p turbo-density -f $root/docker/multisite/compose.yml -f $here/compose.density.yml"
net_base=turbo-density-base

cleanup() {
    [ "${KEEP:-0}" = 1 ] && { echo "KEEP=1: leaving the stack running; k6 files in $work"; return; }
    if [ "$MODE" = turbo ]; then DB_ROOT_PASSWORD=$dbpass $turbo_dc down -v >/dev/null 2>&1 || true
    else
        docker ps -aq --filter name=tdb- | xargs -r docker rm -f >/dev/null 2>&1 || true
        docker volume ls -q --filter name=tdb- | xargs -r docker volume rm >/dev/null 2>&1 || true
        docker network rm $net_base >/dev/null 2>&1 || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT INT TERM

log() { echo "$*" | tee -a "$out"; }
site() { printf 'site%03d' "$1"; }

containers() {
    if [ "$MODE" = turbo ]; then docker ps -q --filter label=com.docker.compose.project=turbo-density
    else docker ps -q --filter name=tdb-; fi
}
mem_total() { # MiB used by every container of the run (cgroup usage minus inactive file cache)
    docker stats --no-stream --format '{{.MemUsage}}' $(containers) | awk '{
        v = $1; u = v; gsub(/[0-9.]/, "", u); n = v + 0
        if (u == "GiB") n *= 1024; else if (u == "KiB" || u == "kB") n /= 1024; else if (u == "B") n /= 1048576
        t += n } END { printf "%.0f", t }'
}
cpu_total() {
    docker stats --no-stream --format '{{.CPUPerc}}' $(containers) | tr -d '%' | awk '{t += $1} END {printf "%.0f", t}'
}

# ---------- setup ----------
if [ "$MODE" = turbo ]; then
    DB_ROOT_PASSWORD=$dbpass WORDPRESS_TAG=$WORDPRESS_TAG $turbo_dc up -d --build --quiet-pull >/dev/null 2>&1
    net=turbo-density_default
else
    docker network create $net_base >/dev/null
    docker run -d --name tdb-db --network $net_base --network-alias db --cpuset-cpus "$BENCH_CPUS" \
        -e MARIADB_ROOT_PASSWORD=$dbpass -v "$root/docker/multisite/mariadb-small.cnf:/etc/mysql/conf.d/zz-turbo.cnf:ro" \
        mariadb:11.4 >/dev/null
    net=$net_base
fi
i=0; until docker exec "$( [ "$MODE" = turbo ] && echo turbo-density-db-1 || echo tdb-db)" \
        mariadb -uroot -p$dbpass -e 'select 1' >/dev/null 2>&1; do
    i=$((i + 1)); [ $i -gt 90 ] && { echo "db not ready" >&2; exit 1; }; sleep 2
done

added=0
add_sites_to() { # add sites until there are $1
    while [ $added -lt "$1" ]; do
        added=$((added + 1)); s=$(site $added)
        if [ "$MODE" = turbo ]; then
            DB_ROOT_PASSWORD=$dbpass COMPOSE_PROJECT_NAME=turbo-density \
                sh "$root/docker/multisite/add-site.sh" "$s" --domain test --no-reload >/dev/null
            docker exec -u www-data turbo-density-php-1 wp --path=/srv/sites/$s post generate \
                --count="$POSTS" --quiet >/dev/null 2>&1
        else
            db=wp_$s
            docker exec tdb-db mariadb -uroot -p$dbpass -e "CREATE DATABASE $db; CREATE USER '$db'@'%' IDENTIFIED BY 'p'; GRANT ALL ON $db.* TO '$db'@'%';"
            docker run -d --name "tdb-$s" --network $net_base --network-alias "$s" --cpuset-cpus "$BENCH_CPUS" \
                -e WORDPRESS_DB_HOST=db -e WORDPRESS_DB_NAME=$db -e WORDPRESS_DB_USER=$db -e WORDPRESS_DB_PASSWORD=p \
                -v "tdb-$s:/var/www/html" "wordpress:$BASELINE_TAG" >/dev/null
            cli="docker run --rm --network $net_base --volumes-from tdb-$s --user 33:33 -e HOME=/tmp
                -e WORDPRESS_DB_HOST=db -e WORDPRESS_DB_NAME=$db -e WORDPRESS_DB_USER=$db -e WORDPRESS_DB_PASSWORD=p
                wordpress:cli wp"
            j=0; until $cli core install --url="http://$s" --title="$s" --admin_user=admin --admin_password=x \
                    --admin_email=a@example.com --skip-email >/dev/null 2>&1; do
                j=$((j + 1)); [ $j -gt 40 ] && { echo "install $s failed" >&2; exit 1; }; sleep 2
            done
            $cli rewrite structure '/%postname%/' >/dev/null 2>&1
            $cli post generate --count="$POSTS" >/dev/null 2>&1
        fi
    done
    if [ "$MODE" = turbo ]; then
        docker exec turbo-density-php-1 kill -USR2 1
        docker exec turbo-density-nginx-1 nginx -s reload
        j=0; until docker exec turbo-density-nginx-1 test -S "/run/php/$(site $added).sock"; do
            j=$((j + 1)); [ $j -gt 100 ] && { echo "pools did not load" >&2; exit 1; }; sleep 0.3
        done
    fi
}

write_targets() { # sites.json with every site's page URLs
    {
        printf '['
        k=1
        while [ $k -le $added ]; do
            s=$(site $k)
            if [ "$MODE" = turbo ]; then base=http://nginx; host="$s.test"
                urls=$(docker exec -u www-data turbo-density-php-1 wp --path=/srv/sites/$s post list --field=url 2>/dev/null)
            else base="http://$s"; host=""
                urls=$(docker run --rm --network $net_base --volumes-from tdb-$s --user 33:33 -e HOME=/tmp \
                    -e WORDPRESS_DB_HOST=db -e WORDPRESS_DB_NAME=wp_$s -e WORDPRESS_DB_USER=wp_$s -e WORDPRESS_DB_PASSWORD=p \
                    wordpress:cli wp post list --field=url 2>/dev/null)
            fi
            paths=$(printf '%s\n' "/" $(printf '%s\n' "$urls" | sed -E 's#^https?://[^/]+##') | awk 'NF{printf "%s\"%s\"", (n++?",":""), $0}')
            printf '%s{"base":"%s","host":"%s","paths":[%s]}' "$( [ $k -gt 1 ] && echo ,)" "$base" "$host" "$paths"
            k=$((k + 1))
        done
        printf ']'
    } > "$work/sites.json"
}

log "nexcore-turbo density benchmark $(date -Iseconds)  mode=$MODE"
log "host: $(uname -srm), cpus=$BENCH_CPUS (k6: ${K6_CPUS:-any}), budget ${MEM_BUDGET_MB} MiB, p95 <= ${P95_MS} ms"
log "load: $RATE_PER_SITE visits/s per site, $(awk "BEGIN{print $UNCACHED*100}")% uncached searches, $WARM warm-up then $DUR measured per step, $POSTS posts per site"
log "sites  rate/s  p95(ms)  p95-uncached(ms)  errors  mem(MiB)  cpu(%)  idle-mem(MiB)  result  notes"

crawled=0
crawl_new_sites() { # view every page of newly added sites once, like a site that has been online for a while
    python3 - "$work/sites.json" "$crawled" > "$work/crawl.txt" <<'PY'
import json, sys
sites = json.load(open(sys.argv[1]))[int(sys.argv[2]):]
for s in sites:
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
    # Measure sites that have been online for a while, not their very first
    # page views (WordPress builds theme data, caches and transients on first
    # use): every page was viewed once above; now run the traffic mix for WARM.
    docker run --rm ${K6_CPUS:+--cpuset-cpus "$K6_CPUS"} --network "$net" -v "$work:/bench" -e RATE="$rate" \
        -e UNCACHED="$UNCACHED" -e DUR="$WARM" "$K6_IMAGE" run --quiet /bench/density.js >/dev/null 2>&1 || true
    ( sleep $(( ${DUR%s} * 2 / 3 )); mem_total > "$work/mem"; cpu_total > "$work/cpu"
      docker stats --no-stream --format '{{.Name}}={{.CPUPerc}}/{{.MemUsage}}' $(containers) \
          | sed -E 's#turbo-density-|tdb-##; s# / [^ ]*##' | tr '\n' ' ' > "$work/split" ) &
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
fails = m["checks"].get("fails", 0) + 0
print(round(d["p(95)"]), round(u.get("p(95)", 0)), fails)
PY
)
EOM
    rm -f "$work/summary.json.prev"
    [ -n "$p95" ] || { log "k6 produced no summary at $n sites"; exit 1; }
    mem=$(cat "$work/mem"); cpu=$(cat "$work/cpu")
    res=PASS
    [ "$err" -gt 0 ] && res="FAIL(errors)"
    [ "$p95" -gt "$P95_MS" ] && res="FAIL(p95)"
    [ "$mem" -gt "$MEM_BUDGET_MB" ] && res="FAIL(memory)"
    notes=""
    if [ "$MODE" = turbo ]; then
        pmax=$(docker logs --since 90s turbo-density-php-1 2>&1 | grep -c 'process.max' || true)
        pchild=$(docker logs --since 90s turbo-density-php-1 2>&1 | grep -c 'max_children' || true)
        workers=$(docker exec turbo-density-php-1 ps 2>/dev/null | grep -c 'pool site' || true)
        bad=$(docker logs --since 70s turbo-density-nginx-1 2>/dev/null | awk '$9 ~ /^[0-9]+$/ && $9 != 200 {print $9" "$7}' | sort | uniq -c | sort -rn | head -5 | tr '\n' ';')
        fpmerr=$(docker logs --since 130s turbo-density-php-1 2>&1 | grep -E 'WARNING|ERROR|Fatal' | sed -E 's/^\[[^]]*\] //' | sort | uniq -c | sort -rn | head -3 | tr '\n' ';')
        notes="fpm-cap-hits=$pmax pool-cap-hits=$pchild workers-now=$workers non200=[$bad] fpm=[$fpmerr] split: $(cat "$work/split")"
    fi
    printf '%5s  %6s  %7s  %16s  %6s  %8s  %6s  %13s  %s  %s\n' "$n" "$rate" "$p95" "$p95u" "$err" "$mem" "$cpu" "$idle" "$res" "$notes" | tee -a "$out"
    [ "$res" = PASS ] || [ "${CONTINUE:-0}" = 1 ] || break   # CONTINUE=1: measure every step anyway
done
log "saved: $out"
