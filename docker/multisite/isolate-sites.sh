#!/bin/sh
# Moves sites made before per-site users (all running as www-data) to their own uid, as
# add-site.sh does for new sites. Safe to run again: sites that already have one are skipped.
#   sh isolate-sites.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dc() { docker compose -f "$here/compose.yml" "$@"; }
dc exec -T php sh -c '
    set -e; NGINX_GID=101
    next=$(n=30000; for s in /srv/sites/*/; do [ -d "$s" ] || continue; u=$(stat -c %u "$s"); [ "$u" -gt "$n" ] && n=$u; done; echo $((n + 1)))
    for d in /srv/sites/*/; do
        d=${d%/}; name=${d##*/}
        [ -f "/usr/local/etc/php-fpm.d/site-$name.conf" ] || continue
        [ "$(stat -c %u "$d")" -ge 30001 ] && continue                     # already isolated
        uid=$next; next=$((next + 1))
        mkdir -p "$d/.turbo-tmp"
        find "$d" \( -type d -o -type f \) -exec chown "$uid:$NGINX_GID" {} +   # never follows the links into /srv/core
        find "$d" -type d -exec chmod 2750 {} +
        find "$d" -type f -exec chmod 0640 {} +
        chown "$uid:$uid" "$d/.turbo-tmp" "$d/wp-config.php" && chmod 0700 "$d/.turbo-tmp" && chmod 0600 "$d/wp-config.php"
        children=$(sed -n "s/^pm.max_children = //p" "/usr/local/etc/php-fpm.d/site-$name.conf")
        sed -e "s/__SITE__/$name/g" -e "s/__UID__/$uid/g" -e "s/__CHILDREN__/${children:-4}/g" /opt/turbo/pool.conf.template \
            > "/usr/local/etc/php-fpm.d/site-$name.conf"
        echo "site $name -> uid $uid"
    done
    php-fpm -t >/dev/null 2>&1 && kill -USR2 1'
