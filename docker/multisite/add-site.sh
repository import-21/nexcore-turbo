#!/bin/sh
# Adds one WordPress site to the multi-site stack.
#   sh add-site.sh <name> [--domain example.test] [--title T] [--admin-email a@b] [--children 4] [--no-reload]
# --no-reload: write the pool but let the caller reload PHP-FPM once (bulk adds).
# The site answers on http://<name>.<domain> (any domain whose first label is <name>).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
name=${1:-}; shift || true
domain=localhost; title=""; email=admin@example.com; children=4; reload=1
while [ $# -gt 0 ]; do
    case "$1" in
        --domain) shift; domain=$1 ;;
        --title) shift; title=$1 ;;
        --admin-email) shift; email=$1 ;;
        --children) shift; children=$1 ;;
        --no-reload) reload=0 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
case "$name" in
    ""|*[!a-z0-9-]*|-*) echo "site name must be lowercase letters, digits and '-'" >&2; exit 2 ;;
esac
[ ${#name} -le 41 ] || { echo "site name too long" >&2; exit 2; }
case "$children" in ""|*[!0-9]*) echo "--children must be a number" >&2; exit 2 ;; esac

dc() { docker compose -f "$here/compose.yml" "$@"; }
php() { dc exec -T "$@"; }

if php php test -e "/srv/sites/$name"; then echo "site $name already exists" >&2; exit 1; fi

i=0   # the database refuses connections while it initialises on first start
until php db sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "SELECT 1"' >/dev/null 2>&1; do
    i=$((i + 1)); [ $i -gt 60 ] && { echo "database not reachable" >&2; exit 1; }; sleep 2
done

db="wp_$(echo "$name" | tr '-' '_')"
pass=$(od -An -N18 -tx1 /dev/urandom | tr -d ' \n')
php db sh -c "mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" -e \"
    CREATE DATABASE \\\`$db\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER '$db'@'%' IDENTIFIED BY '$pass';
    GRANT ALL PRIVILEGES ON \\\`$db\\\`.* TO '$db'@'%';\""

# The site gets its own wp-config.php and wp-content; everything else links to the shared core.
php php sh -c '
    set -e; d=/srv/sites/'"$name"'
    mkdir -p "$d/wp-content/plugins" "$d/wp-content/themes" "$d/wp-content/uploads" "$d/wp-content/upgrade"
    for f in /srv/core/*; do
        case "${f##*/}" in wp-content|wp-config.php|wp-config-sample.php|readme.html|license.txt) continue ;; esac
        ln -s "$f" "$d/${f##*/}"
    done
    for t in /srv/core/wp-content/themes/*/; do ln -s "${t%/}" "$d/wp-content/themes/"; done
    cp /srv/core/wp-content/index.php "$d/wp-content/"
    chown -R www-data:www-data "$d/wp-content" && chown www-data:www-data "$d"'
php -u www-data php wp --path="/srv/sites/$name" config create --dbname="$db" --dbuser="$db" \
    --dbpass="$pass" --dbhost=db --skip-check --quiet
php -u www-data php wp --path="/srv/sites/$name" config set WP_CONTENT_DIR "/srv/sites/$name/wp-content" --quiet
php -u www-data php wp --path="/srv/sites/$name" config set WP_AUTO_UPDATE_CORE false --raw --quiet
# Refresh-on-update: a per-site secret shared only with nginx, and the shared mu-plugin.
refresh=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
php -u www-data php wp --path="/srv/sites/$name" config set WPMU_PLUGIN_DIR /srv/core/turbo-mu-plugins --quiet
php -u www-data php wp --path="/srv/sites/$name" config set TURBO_REFRESH_URL http://nginx --quiet
php -u www-data php wp --path="/srv/sites/$name" config set TURBO_REFRESH_SECRET "$refresh" --quiet
php php sh -c "printf '\"~^%s\$\" 1;\\n' '$refresh' > /srv/refresh/$name.map"
admin_pass=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
php -u www-data php wp --path="/srv/sites/$name" core install --url="http://$name.$domain" \
    --title="${title:-$name}" --admin_user=admin --admin_password="$admin_pass" \
    --admin_email="$email" --skip-email --quiet
php -u www-data php wp --path="/srv/sites/$name" rewrite structure '/%postname%/' --quiet

php php sh -c "sed -e 's/__SITE__/$name/g' -e 's/__CHILDREN__/$children/g' /opt/turbo/pool.conf.template \
    > /usr/local/etc/php-fpm.d/site-$name.conf && php-fpm -t >/dev/null 2>&1"
if [ "$reload" = 0 ]; then echo "site $name: http://$name.$domain  admin / $admin_pass (pool not loaded yet)"; exit 0; fi
php php kill -USR2 1
php nginx nginx -s reload 2>/dev/null
i=0   # FPM re-reads its config asynchronously; wait for the new pool's socket
until php nginx test -S "/run/php/$name.sock"; do
    i=$((i + 1)); [ $i -gt 50 ] && { echo "pool for $name did not start (see: docker compose logs php)" >&2; exit 1; }; sleep 0.2
done
echo "site $name: http://$name.$domain  admin / $admin_pass"
