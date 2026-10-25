#!/bin/sh
# Functional test of docker/python-multisite: routing, caching, isolation,
# scale-to-zero, refresh-on-update, crash back-off, any-WSGI sites.
#   HTTP_PORT=18400 PYTHON_TAG=3.12-slim DJANGO="django==5.2.*" tests/python-multisite/run.sh
set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
here="$root/tests/python-multisite"
. "$root/tests/lib/assert.sh"
: "${HTTP_PORT:=18400}"
ps_dir="$root/docker/python-multisite"
export COMPOSE_PROJECT_NAME="turbopytest$HTTP_PORT" HTTP_PORT TURBO_CACHE_TTL=60s TURBO_IDLE="${TEST_IDLE:-4}" TURBO_MAX_ACTIVE=3
dc() { docker compose -f "$ps_dir/compose.yml" "$@"; }
cleanup() { [ "${KEEP:-0}" = 1 ] || dc down -v --remove-orphans >/dev/null 2>&1; }
trap cleanup EXIT INT TERM
B="http://127.0.0.1:$HTTP_PORT"
get() { curl -s -m 20 -H "Host: $1.test" "$B$2"; }
code() { curl -s -m 20 -o /dev/null -w '%{http_code}' -H "Host: $1.test" "$B$2"; }
status() { cache_status -m 20 -H "Host: $1.test" "$B$2"; }
as_site() { s=$1; shift; dc exec -T app python -m nexcore_turbo.multisite run "$s" "$@"; }
site_procs() { dc exec -T app sh -c "ps -eo uid=,args= | awk '\$1 == $1' | grep -c turbo || true"; }   # by uid

echo "== python multi-site stack (port $HTTP_PORT, ${PYTHON_TAG:-3.12-slim}, ${DJANGO:-django==5.2.*}, ${GUNICORN:-gunicorn==23.*}${DOCKER_DEFAULT_PLATFORM:+, $DOCKER_DEFAULT_PLATFORM})"
dc up -d --build --quiet-pull >/dev/null 2>&1 || { dc up -d --build; exit 1; }
dc exec -T app python -c "import django, gunicorn, sys; print('   python', sys.version.split()[0], 'django', django.get_version(), 'gunicorn', gunicorn.__version__)"

for s in alpha beta gamma; do
    out=$(sh "$ps_dir/add-site.sh" $s --domain test --posts 5 2>&1); rc=$?
    expect_eq "add-site $s" "0" "$rc"; [ $rc = 0 ] || echo "$out" | tail -5
done
out=$(sh "$ps_dir/add-site.sh" alpha --domain test 2>&1); expect_match "duplicate site refused" 'already exists' "$out"
out=$(sh "$ps_dir/add-site.sh" '../etc' 2>&1); expect_match "path traversal name refused" 'site name must be' "$out"
out=$(sh "$ps_dir/add-site.sh" evil --wsgi 'os;system' 2>&1); expect_match "odd --wsgi refused" 'module.path:attr' "$out"

echo "-- routing and caching"
expect_eq "alpha home 200" "200" "$(code alpha /)"
expect_match "alpha serves alpha" '<title>alpha\.test' "$(get alpha /)"
expect_match "beta serves beta" '<title>beta\.test' "$(get beta /)"
expect_eq "post page 200" "200" "$(code alpha /p/post-1/)"
expect_eq "unknown site 404" "404" "$(code nosuch /)"
expect_eq "bare IP host 404" "404" "$(http_code -m 10 "$B/")"
status alpha / >/dev/null
expect_eq "alpha cached" "HIT" "$(status alpha /)"
expect_match "alpha cache never returns beta" '<title>alpha\.test' "$(get alpha /)"
expect_match "beta cache never returns alpha" '<title>beta\.test' "$(get beta /)"
expect_eq "search bypasses cache" "BYPASS" "$(status alpha '/?s=lorem')"
expect_match "search runs SQL" '検索結果' "$(get alpha '/?s=lorem')"
expect_eq "admin bypasses cache" "BYPASS" "$(status alpha /admin/login/)"
expect_eq "session cookie bypasses cache" "BYPASS" "$(cache_status -H 'Host: alpha.test' -H 'Cookie: sessionid=abc' "$B/")"
status alpha /admin/login/ >/dev/null
expect_no_match "login page (sets csrftoken) never cached" '^HIT$' "$(status alpha /admin/login/)"
expect_eq "static file from nginx" "200" "$(code alpha /static/admin/css/base.css)"
expect_eq "admin login works" "200" "$(code alpha /admin/login/)"

echo "-- isolation between sites"
dc cp "$here/probe.py" app:/tmp/probe.py >/dev/null 2>&1 && dc exec -T app chmod 644 /tmp/probe.py
p=$(as_site alpha python /tmp/probe.py beta 2>&1)
expect_match "alpha runs as its own uid" '^uid=2000[0-9]' "$p"
expect_match "alpha cannot read beta's secrets" '^env=blocked' "$p"
expect_match "alpha cannot list beta's data" '^data=blocked' "$p"
expect_match "alpha cannot list beta's code" '^app=blocked' "$p"
expect_match "alpha cannot connect to beta's socket" '^sock=blocked' "$p"
expect_match "alpha cannot signal the server" '^kill1=blocked' "$p"
get alpha '/?s=held' >/dev/null
p=$(as_site alpha python /tmp/probe.py beta 2>&1)
expect_match "running alpha holds only its own socket" '^held=alpha\.sock$' "$p"
uids=$(dc exec -T app sh -c "ps -eo uid=,args= | grep 'nexcore_turbo.multisite serve' | awk '{print \$1}' | sort -u | tr '\n' ' '")
expect_match "sites never run as root" '^0 2000[0-9] ' "$uids"

echo "-- scale to zero"
alpha_uid=$(dc exec -T app stat -c %u /srv/sites/alpha)
get alpha '/?s=wake' >/dev/null
expect_match "alpha running after a request" '^[1-9]' "$(site_procs "$alpha_uid")"
sleep $((TURBO_IDLE + 4))
expect_eq "alpha stopped after TURBO_IDLE" "0" "$(site_procs "$alpha_uid")"
t=$(curl -s -m 20 -o /dev/null -w '%{http_code} %{time_total}' -H 'Host: alpha.test' "$B/?s=cold")
expect_match "cold start answers" '^200 ' "$t"
expect_eq "cold start under ${COLD_MAX:-2}s" "yes" "$(echo "$t" | awk -v m="${COLD_MAX:-2}" '{print ($2 < m) ? "yes" : "no " $2}')"

echo "-- concurrency cap (TURBO_MAX_ACTIVE=3)"
sleep $((TURBO_IDLE + 2))
for s in alpha beta gamma; do sh "$ps_dir/add-site.sh" ${s}2 --domain test >/dev/null 2>&1; done
t0=$(date +%s)
codes=$(for s in alpha beta gamma alpha2 beta2 gamma2; do (code $s '/?s=cap') & done; wait)
t1=$(date +%s)
expect_eq "6 sites at once with 3 slots all answer" "200200200200200200" "$(echo "$codes" | tr -d ' \n')"
expect_eq "full slots free up by stopping the least recently used site (not after TURBO_IDLE)" "yes" \
    "$( [ $((t1 - t0)) -lt "$TURBO_IDLE" ] && echo yes || echo "no ($((t1 - t0))s)")"

echo "-- refresh on update"
status beta /p/post-1/ >/dev/null; status beta /p/post-1/ >/dev/null
as_site beta python manage.py shell -c "from blog.models import Post; p = Post.objects.get(slug='post-1'); p.title = 'Updated title'; p.save()" >/dev/null 2>&1
sleep 1
expect_match "post page refreshed at once" 'Updated title' "$(get beta /p/post-1/)"
expect_match "home page refreshed at once" 'Updated title' "$(get beta /)"
expect_eq "refreshed page served from cache" "HIT" "$(status beta /p/post-1/)"
expect_eq "wrong secret does not refresh" "HIT" "$(cache_status -H 'Host: beta.test' -H 'X-Turbo-Refresh: 0123456789abcdef0123456789abcdef' "$B/p/post-1/")"
sec=$(dc exec -T app sh -c 'grep TURBO_REFRESH_SECRET /srv/sites/gamma/turbo.env | cut -d= -f2')
expect_eq "another site's secret does not refresh" "HIT" "$(cache_status -H 'Host: beta.test' -H "X-Turbo-Refresh: $sec" "$B/p/post-1/")"

echo "-- any WSGI app (Flask with requirements.txt)"
out=$(sh "$ps_dir/add-site.sh" flasky --domain test --from "$here/flaskapp" --wsgi app:app 2>&1); rc=$?
expect_eq "add Flask site" "0" "$rc"; [ $rc = 0 ] || echo "$out" | tail -5
expect_match "Flask site answers as its own uid" 'flask site flasky uid=2000[0-9]' "$(get flasky /)"

echo "-- broken site"
sh "$ps_dir/add-site.sh" broken --domain test --from "$here/broken" --wsgi broken:application >/dev/null 2>&1
c1=$(code broken /); c2=$(code broken /)
expect_match "broken site fails fast (502/503)" '^50[23]$' "$c1"
expect_match "broken site keeps failing fast" '^50[23]$' "$c2"
starts=$(dc logs app 2>&1 | grep -c 'site broken exited')
expect_match "broken site backs off instead of fork-looping" '^[1-3]$' "$starts"
expect_eq "other sites unaffected" "200" "$(code gamma '/?s=ok')"

echo "-- remove site at runtime"
sh "$ps_dir/remove-site.sh" gamma >/dev/null 2>&1
sleep 1
expect_eq "removed site 404" "404" "$(code gamma /)"
expect_eq "removed site socket gone" "no" "$(dc exec -T app sh -c 'test -S /run/turbo/gamma.sock && echo yes || echo no')"
expect_eq "remaining site fine" "200" "$(code beta '/?s=after')"

echo "-- site stopped and started again while it runs"
get beta '/?s=running' >/dev/null
dc exec -T app sh -c 'mv /srv/sites/beta /srv/sites/.off-beta && kill -HUP 1 && sleep 0.05 && mv /srv/sites/.off-beta /srv/sites/beta && kill -HUP 1'
sleep 3
expect_eq "site answers after stop + start" "200" "$(code beta '/?s=back')"
expect_eq "server survived (no restart)" "0" "$(docker inspect -f '{{.RestartCount}}' "${COMPOSE_PROJECT_NAME}-app-1")"

echo "-- clean shutdown"
dc stop -t 20 app >/dev/null 2>&1
expect_eq "server exits 0 on SIGTERM" "0" "$(docker inspect -f '{{.State.ExitCode}}' "${COMPOSE_PROJECT_NAME}-app-1")"

summary "python-multisite"
