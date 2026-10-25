#!/bin/sh
# Functional test of docker/multisite: isolation between sites, caching, idle pools.
#   HTTP_PORT=18300 tests/multisite/run.sh
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
. "$root/tests/lib/assert.sh"
: "${HTTP_PORT:=18300}"
ms="$root/docker/multisite"
export COMPOSE_PROJECT_NAME="turbomstest$HTTP_PORT" HTTP_PORT DB_ROOT_PASSWORD="root-$$" TURBO_CACHE_TTL=60s
dc() { docker compose -f "$ms/compose.yml" "$@"; }
cleanup() { [ "${KEEP:-0}" = 1 ] || dc down -v --remove-orphans >/dev/null 2>&1; }
trap cleanup EXIT INT TERM
B="http://127.0.0.1:$HTTP_PORT"
get() { curl -s -H "Host: $1.test" "$B$2"; }
code() { curl -s -o /dev/null -w '%{http_code}' -H "Host: $1.test" "$B$2"; }
status() { cache_status -H "Host: $1.test" "$B$2"; }

echo "== multisite stack (port $HTTP_PORT)"
dc up -d --build --quiet-pull >/dev/null 2>&1 || { dc up -d --build; exit 1; }
i=0; until dc exec -T db sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "select 1"' >/dev/null 2>&1; do
    i=$((i+1)); [ $i -gt 60 ] && { echo "db not ready"; exit 1; }; sleep 2; done

for s in alpha beta gamma; do
    out=$(sh "$ms/add-site.sh" $s --domain test 2>&1); rc=$?
    expect_eq "add-site $s" "0" "$rc"; [ $rc = 0 ] || echo "$out" | tail -5
done
out=$(sh "$ms/add-site.sh" alpha --domain test 2>&1); expect_match "duplicate site refused" 'already exists' "$out"
out=$(sh "$ms/add-site.sh" '../etc' 2>&1); expect_match "path traversal name refused" 'site name must be' "$out"
sleep 1

echo "-- routing and caching"
expect_eq "alpha home 200" "200" "$(code alpha /)"
expect_match "alpha serves alpha" '<title>alpha' "$(get alpha /)"
expect_match "beta serves beta" '<title>beta' "$(get beta /)"
expect_eq "unknown site 404" "404" "$(code nosuch /)"
expect_eq "bare IP host 404" "404" "$(http_code "$B/")"
status alpha / >/dev/null
expect_eq "alpha cached" "HIT" "$(status alpha /)"
expect_match "alpha cache never returns beta" '<title>alpha' "$(get alpha /)"
expect_match "beta cache never returns alpha" '<title>beta' "$(get beta /)"
expect_eq "admin bypass" "BYPASS" "$(status alpha /wp-login.php)"

echo "-- isolation between sites"
dc exec -T -u www-data php sh -c "mkdir -p /srv/sites/alpha/wp-content && cat > /srv/sites/alpha/peek.php" <<'PHP'
<?php
header('Content-Type: text/plain');
$r = @file_get_contents('/srv/sites/beta/wp-config.php');
echo $r === false ? 'blocked' : 'LEAKED';
echo ' ', function_exists('shell_exec') && !in_array('shell_exec', array_map('trim', explode(',', ini_get('disable_functions')))) ? 'shell' : 'noshell';
PHP
expect_eq "site cannot read another site's files" "blocked noshell" "$(get alpha /peek.php?x=1)"
dc exec -T -u www-data php sh -c "cat > /srv/sites/alpha/core-write.php" <<'PHP'
<?php header('Content-Type: text/plain'); echo @file_put_contents('/srv/core/pwned.php', 'x') === false ? 'readonly' : 'WRITABLE';
PHP
expect_eq "site cannot modify the shared core" "readonly" "$(get alpha /core-write.php?x=1)"
dc exec -T -u www-data php sh -c "cat > /srv/sites/alpha/opc.php" <<'PHP'
<?php header('Content-Type: text/plain'); echo opcache_get_status(false)['opcache_statistics']['num_cached_scripts'];
PHP
for s in alpha beta gamma; do get $s "/?s=warm$s" >/dev/null; done
one=$(get alpha /opc.php?x=1)
for s in alpha beta gamma; do get $s "/?s=again$s" >/dev/null; get $s /wp-login.php >/dev/null; done
three=$(get alpha /opc.php?x=2)
[ "${one:-0}" -gt 100 ] && [ "$three" -le $((one + 30)) ] && pass "WordPress core compiled once for all sites ($one -> $three scripts)" \
    || fail "WordPress core compiled once for all sites" "$one -> $three scripts"
pi=$(dc exec -T -u www-data php wp --path=/srv/sites/beta plugin install hello-dolly --activate 2>&1 | tail -1)
expect_match "plugin installs into the site's own wp-content" 'Success' "$pi"
expect_eq "plugin not visible to other sites" "no" "$(dc exec -T php test -e /srv/sites/alpha/wp-content/plugins/hello-dolly && echo yes || echo no)"
get alpha "/?s=pool" >/dev/null
expect_match "pool runs per site" 'pool alpha' "$(dc exec -T php ps 2>/dev/null)"

echo "-- idle sites use no PHP worker"
get gamma / >/dev/null   # first view renders through PHP
sleep 6
workers=$(dc exec -T php ps 2>/dev/null | grep -c 'pool ' || true)
expect_eq "no PHP workers after idle timeout" "0" "$workers"
for i in 1 2 3 4 5; do get gamma / >/dev/null; done
expect_match "cached hits keep pools idle" '^0$' "$(dc exec -T php ps 2>/dev/null | grep -c 'pool gamma' || true)"

echo "-- refresh on update"
pid=$(dc exec -T -u www-data php wp --path=/srv/sites/beta post create --post_status=publish --post_title=Fresh --post_name=fresh --post_content=v1-content --porcelain | tr -d '\r')
get beta /fresh/ >/dev/null
expect_eq "post cached" "HIT" "$(status beta /fresh/)"
dc exec -T -u www-data php wp --path=/srv/sites/beta post update "$pid" --post_content=v2-content >/dev/null 2>&1
expect_match "update visible immediately" 'v2-content' "$(get beta /fresh/)"
expect_eq "still served from cache" "HIT" "$(status beta /fresh/)"
alpha_secret=$(dc exec -T php sed -n 's/^"~.*|\([0-9a-f]*\)\$".*/\1/p' /srv/refresh/alpha.map | tr -d '\r')
expect_match "per-site secret generated" '^[0-9a-f]{32}$' "$alpha_secret"
expect_eq "site secrets stay out of the web root" "no" "$(dc exec -T php sh -c 'grep -rl "$0" /srv/sites/beta 2>/dev/null' "$alpha_secret" | grep -q . && echo yes || echo no)"
expect_eq "alpha's secret cannot refresh beta" "HIT" "$(cache_status -H 'Host: beta.test' -H "X-Turbo-Refresh: $alpha_secret" "$B/fresh/")"
status alpha / >/dev/null
expect_eq "alpha's secret refreshes alpha" "BYPASS" "$(cache_status -H 'Host: alpha.test' -H "X-Turbo-Refresh: $alpha_secret" "$B/")"

echo "-- add/remove at runtime"
expect_eq "site unknown before adding" "404" "$(code delta /)"
sh "$ms/add-site.sh" delta --domain test >/dev/null 2>&1
expect_eq "new site live immediately (no restart)" "200" "$(code delta /)"
sh "$ms/remove-site.sh" delta >/dev/null 2>&1
sleep 11
expect_eq "removed site 404 (within 10 s)" "404" "$(code delta /?x=1)"
expect_eq "others unaffected" "200" "$(code alpha /?r=1)"

summary "multisite"
