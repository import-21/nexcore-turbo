#!/bin/sh
# Functional test of the Docker WordPress stack.
#
#   WORDPRESS_TAG=php8.3-fpm-alpine NGINX_VERSION=1.26-alpine DB_IMAGE=mariadb:11.4 \
#   HTTP_PORT=18080 tests/wp/run.sh
#
# Brings up a throw-away stack (cache TTL 4s), installs WordPress with wp-cli,
# checks what is and is not cached, then removes everything (KEEP=1 to keep).
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
. "$root/tests/lib/assert.sh"

: "${WORDPRESS_TAG:=php8.3-fpm-alpine}"
: "${NGINX_VERSION:=1.26-alpine}"
: "${DB_IMAGE:=mariadb:11.4}"
: "${HTTP_PORT:=18080}"
: "${PLATFORM:=}"
[ -n "$PLATFORM" ] && : "${INSTALL_TRIES:=400}"
TTL_SECONDS=4
[ -n "$PLATFORM" ] && TTL_SECONDS=20   # emulated PHP is slow; keep entries fresh between checks
proj="turbotest$(echo "$WORDPRESS_TAG$NGINX_VERSION$DB_IMAGE$HTTP_PORT" | cksum | cut -c1-8)"
base="http://localhost:$HTTP_PORT"
export COMPOSE_PROJECT_NAME="$proj" WORDPRESS_TAG NGINX_VERSION DB_IMAGE HTTP_PORT
export DB_PASSWORD="test-$(date +%s)" TURBO_CACHE_TTL="${TTL_SECONDS}s"
# Only nginx and PHP run on $PLATFORM: they are what is under test, and the
# MariaDB entrypoint times out under QEMU emulation.
plat_override=""
if [ -n "$PLATFORM" ]; then
    plat_override=$(mktemp)
    printf 'services:\n  nginx:\n    platform: %s\n  wordpress:\n    platform: %s\n' "$PLATFORM" "$PLATFORM" > "$plat_override"
fi

compose() { docker compose -f "$root/docker/wordpress/compose.yml" ${JIT:+-f "$root/docker/wordpress/compose.jit.yml"} ${plat_override:+-f "$plat_override"} "$@"; }
cleanup() { [ "${KEEP:-0}" = 1 ] || compose down -v --remove-orphans >/dev/null 2>&1; [ -n "$plat_override" ] && rm -f "$plat_override"; }
trap cleanup EXIT INT TERM

echo "== stack: ${JIT:+[JIT] }wordpress:$WORDPRESS_TAG nginx:$NGINX_VERSION $DB_IMAGE ${PLATFORM:-native} (port $HTTP_PORT)"
compose up -d --quiet-pull >/dev/null 2>&1 || { compose up -d; echo "compose up failed"; exit 1; }

wp_ctr="${proj}-wordpress-1"
nginx_ctr="${proj}-nginx-1"
case "$WORDPRESS_TAG" in *alpine*) wp_uid=82 ;; *) wp_uid=33 ;; esac
# wp-cli must run on the same PHP as the site (old cores break on new PHP).
php_ver=$(echo "$WORDPRESS_TAG" | sed -n 's/.*php\([0-9]*\.[0-9]*\).*/\1/p')
wpcli_image="wordpress:cli${php_ver:+-php$php_ver}"
wp() {
    docker run --rm ${PLATFORM:+--platform "$PLATFORM"} --network "${proj}_default" --volumes-from "$wp_ctr" \
        --user "$wp_uid:$wp_uid" -e HOME=/tmp \
        -e WORDPRESS_DB_HOST=db -e WORDPRESS_DB_NAME=wordpress -e WORDPRESS_DB_USER=wordpress \
        -e WORDPRESS_DB_PASSWORD="$DB_PASSWORD" "$wpcli_image" wp "$@"
}

# Wait for the WordPress files and the database. (Not "wp db check": newer
# MariaDB clients in the wp-cli image insist on TLS that older servers lack;
# core install goes through PHP's mysqli like WordPress itself.)
i=0
until wp core install --url="$base" --title=Turbo --admin_user=admin --admin_password=admin-pass \
        --admin_email=admin@example.com --skip-email >/tmp/turbo-install.$$ 2>&1 \
        || grep -q 'already installed' /tmp/turbo-install.$$; do
    i=$((i + 1)); [ $i -gt "${INSTALL_TRIES:-60}" ] && { echo "wp core install failed:"; tail -5 /tmp/turbo-install.$$; docker logs "$wp_ctr" 2>&1 | tail -10; exit 1; }
    sleep 3
done
rm -f /tmp/turbo-install.$$
wp rewrite structure '/%postname%/' >/dev/null
wp option update comment_moderation 0 >/dev/null
wp option update comment_previously_approved 0 >/dev/null
post_id=$(wp post create --post_type=post --post_status=publish --post_title=Hello --post_name=hello-turbo \
    --post_content=original-content --porcelain)
docker exec -u 0 "$wp_ctr" sh -c 'mkdir -p /var/www/html/wp-content/mu-plugins && chown '"$wp_uid:$wp_uid"' /var/www/html/wp-content/mu-plugins'
docker cp "$here/test-mu-plugin.php" "$wp_ctr:/var/www/html/wp-content/mu-plugins/turbo-test.php"
echo "<?php return 'one';" > /tmp/turbo-edit-me.$$ && docker cp /tmp/turbo-edit-me.$$ "$wp_ctr:/var/www/html/wp-content/mu-plugins/turbo-edit-me.inc.php"
rm -f /tmp/turbo-edit-me.$$
docker exec -u 0 "$wp_ctr" chown -R "$wp_uid:$wp_uid" /var/www/html/wp-content/mu-plugins

echo "-- environment"
info=$(curl -s "$base/turbo-test/opcache?i=1")
echo "   $info"
expect_match "opcache enabled with timestamp validation" 'opcache=on validate=1' "$info"
if [ -n "${JIT:-}" ]; then expect_match "JIT active" 'jit=active' "$info"
else expect_match "JIT off unless asked for" 'jit=off' "$info"; fi
workers=$(docker logs "$nginx_ctr" 2>&1 | grep -o 'worker_processes=[0-9]*' | head -1)
expect_match "nginx tune script ran" 'worker_processes=[0-9]+' "$workers"
expect_eq "nginx config valid" "0" "$(docker exec "$nginx_ctr" nginx -t >/dev/null 2>&1; echo $?)"

echo "-- anonymous pages are cached"
s1=$(cache_status "$base/turbo-test/stamp"); s2=$(cache_status "$base/turbo-test/stamp")
expect_eq "first request MISS" "MISS" "$s1"
expect_eq "second request HIT" "HIT" "$s2"
b1=$(curl -s "$base/turbo-test/stamp"); b2=$(curl -s "$base/turbo-test/stamp")
expect_eq "HIT returns identical body" "$b1" "$b2"
cache_status "$base/" >/dev/null
expect_eq "home page HIT" "HIT" "$(cache_status "$base/")"
expect_eq "permalink post page 200" "200" "$(http_code "$base/hello-turbo/")"
expect_eq "permalink post HIT" "HIT" "$(cache_status "$base/hello-turbo/")"
expect_match "HEAD works" '^200$' "$(curl -s -o /dev/null -w '%{http_code}' -I "$base/hello-turbo/")"
gz=$(curl -s -o /dev/null -D - -H 'Accept-Encoding: gzip' "$base/" | tr -d '\r' | grep -i '^content-encoding')
expect_match "gzip enabled" 'gzip' "$gz"

echo "-- bypass rules"
expect_eq "query string BYPASS" "BYPASS" "$(cache_status "$base/turbo-test/stamp?utm=1")"
expect_eq "search BYPASS" "BYPASS" "$(cache_status "$base/?s=hello")"
ps=$(cache_status -X POST -d a=b "$base/turbo-test/stamp")
case "$ps" in HIT|MISS|STALE|UPDATING) fail "POST never cached" "got $ps" ;; *) pass "POST never cached ($ps)" ;; esac
expect_eq "wp-login BYPASS" "BYPASS" "$(cache_status "$base/wp-login.php")"
expect_eq "wp-json BYPASS" "BYPASS" "$(cache_status "$base/wp-json/")"
expect_eq "logged-in cookie BYPASS" "BYPASS" "$(cache_status -b 'wordpress_logged_in_abc=x' "$base/turbo-test/stamp")"
expect_eq "comment author cookie BYPASS" "BYPASS" "$(cache_status -b 'comment_author_abc=x' "$base/turbo-test/stamp")"
expect_eq "woocommerce cart cookie BYPASS" "BYPASS" "$(cache_status -b 'woocommerce_items_in_cart=1' "$base/turbo-test/stamp")"
expect_eq "PHP session cookie BYPASS" "BYPASS" "$(cache_status -b 'PHPSESSID=x' "$base/turbo-test/stamp")"
expect_eq "unrelated cookie still cached" "HIT" "$(cache_status -b '_ga=GA1.1' "$base/turbo-test/stamp")"
expect_eq "Authorization header BYPASS" "BYPASS" "$(cache_status -H 'Authorization: Basic eDp5' "$base/turbo-test/stamp")"
expect_eq "cart path BYPASS" "BYPASS" "$(cache_status "$base/cart/")"
expect_eq "feed BYPASS" "BYPASS" "$(cache_status "$base/feed/")"
expect_eq "sitemap BYPASS" "BYPASS" "$(cache_status "$base/wp-sitemap.xml")"
expect_eq "wp-admin BYPASS" "BYPASS" "$(cache_status "$base/wp-admin/")"

echo "-- application signals are honoured"
cache_status "$base/turbo-test/sets-cookie" >/dev/null
c2=$(curl -s "$base/turbo-test/sets-cookie"); sleep 0.2; c3=$(curl -s "$base/turbo-test/sets-cookie")
expect_eq "Set-Cookie response not stored" "MISS" "$(cache_status "$base/turbo-test/sets-cookie")"
[ "$c2" != "$c3" ] && pass "Set-Cookie page regenerated each time" || fail "Set-Cookie page regenerated each time" "$c2 == $c3"
cache_status "$base/turbo-test/private" >/dev/null
expect_eq "Cache-Control private not stored" "MISS" "$(cache_status "$base/turbo-test/private")"
cache_status "$base/turbo-test/no-store" >/dev/null
expect_eq "Cache-Control no-store not stored" "MISS" "$(cache_status "$base/turbo-test/no-store")"
cache_status "$base/turbo-test/error" >/dev/null
expect_eq "500 response not stored" "MISS" "$(cache_status "$base/turbo-test/error")"

echo "-- hosts do not share cache entries"
cache_status -H 'Host: a.example' "$base/turbo-test/host" >/dev/null
ha=$(curl -s -H 'Host: a.example' "$base/turbo-test/host"); hb=$(curl -s -H 'Host: b.example' "$base/turbo-test/host")
expect_match "host a gets its own page" '^host=a\.example ' "$ha"
expect_match "host b gets its own page" '^host=b\.example ' "$hb"

echo "-- real login / comment flow"
jar=$(mktemp)
curl -s -c "$jar" -b "$jar" -o /dev/null "$base/wp-login.php"
lc=$(curl -s -c "$jar" -b "$jar" -o /dev/null -w '%{http_code}' \
    --data-urlencode log=admin --data-urlencode pwd=admin-pass --data-urlencode wp-submit=Log\ In \
    --data-urlencode redirect_to="$base/wp-admin/" --data-urlencode testcookie=1 "$base/wp-login.php")
expect_eq "login redirects" "302" "$lc"
expect_eq "dashboard reachable when logged in" "200" "$(http_code -b "$jar" "$base/wp-admin/")"
lp=$(curl -s -b "$jar" -D - -o /tmp/turbo-li.$$ "$base/hello-turbo/" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-turbo-cache"{print $2}')
expect_eq "logged-in view of cached post BYPASS" "BYPASS" "$lp"
expect_match "logged-in view shows admin bar" 'wp-admin-bar|id="wpadminbar"' "$(cat /tmp/turbo-li.$$)"
expect_no_match "anonymous cached copy has no admin bar" 'id="wpadminbar"' "$(curl -s "$base/hello-turbo/")"
rm -f /tmp/turbo-li.$$ "$jar"
cjar=$(mktemp)
cc=$(curl -s -c "$cjar" -o /dev/null -w '%{http_code}' --data-urlencode comment=turbo-comment-$$ \
    --data-urlencode author=Tester --data-urlencode email=t@example.com --data-urlencode comment_post_ID="$post_id" \
    --data-urlencode comment_parent=0 --data-urlencode wp-comment-cookies-consent=yes "$base/wp-comments-post.php")
expect_eq "comment post accepted" "302" "$cc"
sleep $((TTL_SECONDS + 1))
expect_match "commenter sees own comment immediately" "turbo-comment-$$" "$(curl -s -b "$cjar" "$base/hello-turbo/")"
rm -f "$cjar"

echo "-- content updates appear after the TTL"
cache_status "$base/hello-turbo/" >/dev/null
wp post update "$post_id" --post_content=updated-content >/dev/null
expect_match "cached copy within TTL still old" 'original-content' "$(curl -s "$base/hello-turbo/")"
sleep $((TTL_SECONDS + 2))
curl -s -o /dev/null "$base/hello-turbo/"   # background refresh trigger
sleep 1
expect_match "new content after TTL" 'updated-content' "$(curl -s "$base/hello-turbo/")"

echo "-- PHP file edits are picked up (OPcache revalidation)"
v1=$(curl -s "$base/turbo-test/edit-me?x=1")
docker exec -u "$wp_uid" "$wp_ctr" sh -c "echo \"<?php return 'two';\" > /var/www/html/wp-content/mu-plugins/turbo-edit-me.inc.php"
sleep 4
v2=$(curl -s "$base/turbo-test/edit-me?x=2")
expect_eq "before edit" "version=one" "$v1"
expect_eq "after edit (no restart)" "version=two" "$v2"
pi=$(wp plugin install hello-dolly --activate 2>&1 | tail -1)
expect_match "plugin install + activate via wp-cli" 'Success|activated' "$pi"

echo "-- security rules"
docker exec -u 0 "$wp_ctr" sh -c "mkdir -p /var/www/html/wp-content/uploads && echo '<?php echo \"pwned\";' > /var/www/html/wp-content/uploads/evil.php"
expect_eq "PHP inside uploads is denied" "403" "$(http_code "$base/wp-content/uploads/evil.php")"
expect_eq "dotfiles denied" "403" "$(http_code "$base/.htaccess")"
expect_eq "missing .php is 404, not passed to FPM" "404" "$(http_code "$base/wp-content/nope.php")"
expect_eq "path-info trick in uploads denied" "403" "$(http_code "$base/wp-content/uploads/x.jpg/y.php")"
expect_eq "path-info trick elsewhere is 404" "404" "$(http_code "$base/wp-includes/images/w-logo-blue.png/y.php")"
expect_eq "static CSS served" "200" "$(http_code "$base/wp-includes/css/dashicons.min.css")"
ct=$(curl -s -o /dev/null -w '%{content_type}' "$base/wp-includes/css/dashicons.min.css")
expect_match "static CSS mime type" 'text/css' "$ct"

echo "-- restart keeps working (tmpfs cache is emptied)"
compose restart nginx >/dev/null 2>&1
i=0; until [ "$(http_code "$base/turbo-test/stamp")" = 200 ] || [ $i -gt 30 ]; do i=$((i+1)); sleep 1; done
expect_eq "MISS after restart" "MISS" "$(cache_status "$base/hello-turbo/")"
expect_eq "HIT again" "HIT" "$(cache_status "$base/hello-turbo/")"

errors=$(docker logs "$nginx_ctr" 2>&1 | grep -E '\[(emerg|alert|crit)\]' | head -3)
# QEMU user-mode emulation has no io_setup(); real arm64 kernels do.
[ -n "$PLATFORM" ] && errors=$(printf '%s' "$errors" | grep -v 'io_setup() failed')
expect_eq "no emerg/alert/crit in nginx log" "" "$errors"

summary "${JIT:+[JIT] }wordpress:$WORDPRESS_TAG nginx:$NGINX_VERSION $DB_IMAGE ${PLATFORM:-native}"
