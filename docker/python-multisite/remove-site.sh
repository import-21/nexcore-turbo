#!/bin/sh
# Removes a site from the python multi-site stack (code, data and cache secret).
#   sh remove-site.sh <name>
set -eu
here=$(cd "$(dirname "$0")" && pwd)
name=${1:-}
case "$name" in ""|*[!a-z0-9-]*|-*) echo "usage: remove-site.sh <name>" >&2; exit 2 ;; esac
dc() { docker compose -f "$here/compose.yml" "$@"; }
dc exec -T app sh -c "test -d /srv/sites/$name || { echo 'no site $name' >&2; exit 1; }
    rm -rf /srv/sites/$name /srv/refresh/$name.map && kill -HUP 1"
dc exec -T nginx nginx -s reload >/dev/null 2>&1
echo "site $name removed"
