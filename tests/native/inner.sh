#!/bin/sh
# Runs inside a distro container: installs nginx+php-fpm from the distro,
# runs native/install.sh, starts the services and checks the behaviour.
set -u
. /src/tests/lib/assert.sh
distro=$1
log() { printf '%s\n' "$*"; }

case "$distro" in
    ubuntu*|debian*)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null && apt-get install -y -qq nginx php-fpm curl procps >/dev/null 2>&1 || exit 10
        rm -f /etc/nginx/sites-enabled/default
        fpm=$(ls /usr/sbin/php-fpm* | head -1); v=$(echo "$fpm" | sed 's/.*php-fpm//')
        sock=/run/php/php$v-fpm.sock; mkdir -p /run/php
        start_fpm() { $fpm -D; } ;;
    rocky*|almalinux*|amazonlinux*|fedora*)
        dnf install -y -q nginx php-fpm php-opcache php-cli procps-ng >/dev/null 2>&1 || exit 10
        command -v curl >/dev/null || dnf install -y -q curl-minimal >/dev/null 2>&1 || dnf install -y -q curl >/dev/null 2>&1
        sock=/run/php-fpm/www.sock; mkdir -p /run/php-fpm
        start_fpm() { php-fpm -D; } ;;
    alpine*)
        apk add -q nginx curl procps >/dev/null || exit 10
        p=$(apk search -q 'php8*-fpm' | sort -V | tail -1); n=${p%-fpm}
        apk add -q "$n-fpm" "$n-opcache" >/dev/null || exit 10
        sock=127.0.0.1:9000
        start_fpm() { "$(ls /usr/sbin/php-fpm* | head -1)" -D; } ;;
    *) echo "unknown distro $distro"; exit 2 ;;
esac

log "   nginx $(nginx -v 2>&1 | sed 's/.*\///')  php $(php -r 'echo PHP_VERSION;' 2>/dev/null || ls /usr/sbin/php-fpm*)"

mkdir -p /srv/app/wp-content/uploads
cp /src/tests/native/app/* /srv/app/
echo '<?php echo "pwned";' > /srv/app/wp-content/uploads/evil.php
chmod -R a+rX /srv/app
chmod a+w /srv/app/edit-me.inc.php

out=$(sh /src/native/install.sh --dry-run 2>&1); rc=$?
expect_eq "installer --dry-run exits 0" "0" "$rc"
expect_match "dry-run writes nothing" 'dry run finished' "$out"
[ -e /etc/nginx/turbo/turbo-http.conf ] && fail "dry-run left files" || pass "dry-run left no files"

out=$(sh /src/native/install.sh --ttl 4s 2>&1); rc=$?
echo "$out" | sed 's/^/     /'
expect_eq "installer exits 0" "0" "$rc"
expect_match "installer found PHP conf.d" '99-turbo-opcache.ini|PHP' "$(cat /etc/nginx/turbo/.installed 2>/dev/null)"
upstream="$sock"; case "$sock" in /*) upstream="unix:$sock" ;; esac
case "$distro" in alpine*) site_dir=/etc/nginx/http.d ;; *) site_dir=/etc/nginx/conf.d ;; esac
cat > $site_dir/turbo-test-site.conf <<CONF
server {
    listen 8081;
    server_name _;
    root /srv/app;
    set \$turbo_php_upstream $upstream;
    include /etc/nginx/turbo/turbo-wordpress.conf;
}
CONF
expect_eq "nginx -t with site" "0" "$(nginx -t >/dev/null 2>&1; echo $?)"
start_fpm || { fail "php-fpm starts"; summary "$distro"; exit 1; }
nginx || { fail "nginx starts"; summary "$distro"; exit 1; }
sleep 1
B=http://127.0.0.1:8081

info=$(curl -s "$B/info?x=1"); log "   $info"
expect_match "opcache on, validating, freq 2" 'opcache=on validate=1 freq=2' "$info"
expect_eq "MISS then" "MISS" "$(cache_status "$B/page")"
expect_eq "HIT" "HIT" "$(cache_status "$B/page")"
expect_eq "front controller route cached" "HIT" "$(cache_status "$B/page")"
expect_eq "query BYPASS" "BYPASS" "$(cache_status "$B/page?a=1")"
expect_eq "logged-in BYPASS" "BYPASS" "$(cache_status -b wordpress_logged_in_x=1 "$B/page")"
expect_eq "wp-admin BYPASS" "BYPASS" "$(cache_status "$B/wp-admin/")"
expect_eq "Authorization BYPASS" "BYPASS" "$(cache_status -H 'Authorization: Bearer x' "$B/page")"
ps=$(cache_status -X POST -d a=1 "$B/page")
case "$ps" in HIT|MISS) fail "POST not cached" "$ps" ;; *) pass "POST not cached" ;; esac
cache_status "$B/sets-cookie" >/dev/null
expect_eq "Set-Cookie not stored" "MISS" "$(cache_status "$B/sets-cookie")"
cache_status "$B/private" >/dev/null
expect_eq "private not stored" "MISS" "$(cache_status "$B/private")"
cache_status -H 'Host: a.test' "$B/host" >/dev/null
expect_match "host isolation" '^host=b\.test' "$(curl -s -H 'Host: b.test' "$B/host")"
p1=$(curl -s "$B/ttl"); sleep 6; curl -s -o /dev/null "$B/ttl"; sleep 1; p2=$(curl -s "$B/ttl")
[ "$p1" != "$p2" ] && pass "entry refreshed after --ttl 4s" || fail "entry refreshed after --ttl 4s" "$p1"
secret=$(sed -n 's/^"~^\([A-Za-z0-9_-]*\)\$".*/\1/p' /etc/nginx/turbo/refresh/site.map)
expect_match "installer generated a refresh secret" '^[0-9a-f]{32}$' "$secret"
r1=$(curl -s "$B/refresh-me"); sleep 0.2
expect_eq "wrong refresh secret ignored" "$r1" "$(curl -s -H 'X-Turbo-Refresh: nope' "$B/refresh-me")"
curl -s -o /dev/null -H "X-Turbo-Refresh: $secret" "$B/refresh-me"
r2=$(curl -s "$B/refresh-me")
[ "$r1" != "$r2" ] && pass "refresh header replaces the cached page" || fail "refresh header replaces the cached page" "$r1"
v1=$(curl -s "$B/edit-me?x=1"); echo "<?php return 'two';" > /srv/app/edit-me.inc.php; sleep 4
expect_eq "PHP edits picked up without restart" "version=one version=two" "$v1 $(curl -s "$B/edit-me?x=2")"
expect_eq "uploads PHP denied" "403" "$(http_code "$B/wp-content/uploads/evil.php")"
expect_eq "missing php 404" "404" "$(http_code "$B/nope.php")"
expect_eq "cache files written under /var/cache/nginx/turbo" "ok" "$(ls -R /var/cache/nginx/turbo 2>/dev/null | grep -Eq '^[0-9a-f]{32}$' && echo ok)"
fpm_pm=$(grep -h '^pm = ' $(cat /etc/nginx/turbo/.installed | grep zz-turbo.conf) 2>/dev/null)
[ -n "$fpm_pm" ] && pass "FPM pool override installed ($fpm_pm)" || log "   (no [www] pool override on this distro)"

sh /src/native/install.sh --uninstall >/dev/null 2>&1
expect_eq "uninstall removes snippets" "no" "$([ -e /etc/nginx/turbo/turbo-http.conf ] && echo yes || echo no)"
rm -f $site_dir/turbo-test-site.conf
expect_eq "nginx config valid after uninstall" "0" "$(nginx -t >/dev/null 2>&1; echo $?)"

# A broken config must be rolled back.
echo "this is not nginx syntax" > $site_dir/broken.conf
sh /src/native/install.sh >/dev/null 2>&1; rc=$?
rm -f $site_dir/broken.conf
expect_eq "installer fails on broken nginx config" "1" "$rc"
expect_eq "and rolls its files back" "no" "$([ -e /etc/nginx/turbo/turbo-http.conf ] && echo yes || echo no)"

summary "native $distro"
