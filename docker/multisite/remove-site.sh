#!/bin/sh
# Removes a site added with add-site.sh (files, database, pool).  sh remove-site.sh <name>
set -eu
here=$(cd "$(dirname "$0")" && pwd)
name=${1:-}
case "$name" in ""|*[!a-z0-9-]*|-*) echo "invalid site name" >&2; exit 2 ;; esac
dc() { docker compose -f "$here/compose.yml" "$@"; }
db="wp_$(echo "$name" | tr '-' '_')"
dc exec -T php sh -c "rm -rf /srv/sites/$name && rm -f /usr/local/etc/php-fpm.d/site-$name.conf /srv/refresh/$name.map && kill -USR2 1"
dc exec -T nginx nginx -s reload 2>/dev/null
sh "$here/purge-site.sh" "$name" >/dev/null
dc exec -T db sh -c "mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" -e \"DROP DATABASE IF EXISTS \\\`$db\\\`; DROP USER IF EXISTS '$db'@'%';\""
echo "removed $name"
