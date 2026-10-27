#!/bin/sh
# Drops every cached page of one site at once (pages live up to TURBO_CACHE_TTL, 24h by
# default): after removing content that must not stay visible, or when in doubt.
#   sh purge-site.sh <name>
set -eu
here=$(cd "$(dirname "$0")" && pwd)
name=${1:-}
case "$name" in ""|*[!a-z0-9-]*|-*) echo "usage: purge-site.sh <name>" >&2; exit 2 ;; esac
# The cache key starts with scheme + method + host (turbo-http.conf), so a site's files are
# the ones whose KEY line names <name>.<domain>.
n=$(docker compose -f "$here/compose.yml" exec -T nginx sh -c \
    "grep -rlaE '^KEY: https?(https?)?(GET|HEAD)$name\\.' /var/cache/nginx/turbo-proxy 2>/dev/null | tee /tmp/purge.$$ | wc -l; xargs -r rm -f < /tmp/purge.$$; rm -f /tmp/purge.$$; nginx -s reload 2>/dev/null")
# The reload makes nginx let go of open files it keeps for a few seconds (open_file_cache):
# without it a dropped page could still be sent until then. In-flight requests are not cut.
echo "site $name: $n cached page(s) dropped"
