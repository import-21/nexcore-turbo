#!/bin/sh
# nexcore-turbo installer for servers that already run nginx + PHP-FPM
# (Debian/Ubuntu, RHEL/Rocky/Alma/Fedora/Amazon Linux, Alpine).
#
#   sudo sh native/install.sh            install (nginx -t is run; rolled back on failure)
#   sudo sh native/install.sh --dry-run  show what would be written
#   sudo sh native/install.sh --uninstall
#   options: --no-php   --jit   --reload   --ttl 60s
#
# It never edits your server{} blocks. After installing, add to the site:
#     set $turbo_php_upstream unix:/run/php/php8.3-fpm.sock;   # your FPM socket
#     include /etc/nginx/turbo/turbo-wordpress.conf;
# or, to keep your own locations, only inside your PHP location:
#     include /etc/nginx/turbo/turbo-php-cache.conf;
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
dry=0; php=1; jit=0; reload=0; uninstall=0; ttl=60s
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry=1 ;;
        --no-php) php=0 ;;
        --jit) jit=1 ;;
        --reload) reload=1 ;;
        --uninstall) uninstall=1 ;;
        --ttl) shift; ttl="${1:-}" ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
case "$ttl" in ""|*[!0-9smhd]*) echo "invalid --ttl '$ttl'" >&2; exit 2 ;; esac

say() { printf 'turbo: %s\n' "$*"; }
die() { printf 'turbo: error: %s\n' "$*" >&2; exit 1; }
run() { if [ "$dry" = 1 ]; then say "[dry-run] $*"; else "$@"; fi; }
put() { # put <src> <dest>  (src "-" = stdin)
    if [ "$dry" = 1 ]; then say "[dry-run] write $2"; [ "$1" = - ] && cat >/dev/null; return 0; fi
    mkdir -p "$(dirname "$2")"
    if [ "$1" = - ]; then cat > "$2"; else cp "$1" "$2"; fi
    chmod 644 "$2"
    echo "$2" >> "$manifest"
}

command -v nginx >/dev/null 2>&1 || die "nginx not found in PATH"
[ "$dry" = 1 ] || [ "$(id -u)" = 0 ] || die "run as root (or use --dry-run)"

nginx_conf=$(nginx -V 2>&1 | sed -n 's/.*--conf-path=\([^ ]*\).*/\1/p')
[ -n "$nginx_conf" ] || nginx_conf=/etc/nginx/nginx.conf
nginx_dir=$(dirname "$nginx_conf")
manifest="$nginx_dir/turbo/.installed"

if [ "$uninstall" = 1 ]; then
    [ -f "$manifest" ] || die "nothing to uninstall ($manifest missing)"
    while read -r f; do run rm -f "$f"; done < "$manifest"
    run rm -f "$manifest"
    run rmdir "$nginx_dir/turbo/refresh" 2>/dev/null || true
    run rmdir "$nginx_dir/turbo" 2>/dev/null || true
    say "removed. Remove the include lines from your server blocks, then reload nginx and php-fpm."
    exit 0
fi

# http{}-level include directory: the first "include <dir>/*.conf" that sits
# directly inside http { } (Alpine, for example, includes conf.d/ at main level
# and http.d/ inside http).
http_includes=$(awk '
    { l = $0; sub(/#.*/, "", l) }
    l ~ /^[ \t]*http[ \t]*(\{|$)/ { pending = 1 }
    http && depth == http && l ~ /^[ \t]*include[ \t]/ {
        inc = l; sub(/^[ \t]*include[ \t]+/, "", inc); sub(/[ \t]*;.*/, "", inc); print inc
    }
    {
        o = gsub(/\{/, "{", l); c = gsub(/\}/, "}", l)
        depth += o
        if (pending && o > 0) { http = depth; pending = 0 }
        if (c > 0) { depth -= c; if (http && depth < http) http = 0 }
    }' "$nginx_conf")
http_dir=""
set -f   # the include values are globs; keep them literal
for inc in $http_includes; do
    case "$inc" in
        */\*.conf)
            d=${inc%/\*.conf}
            case "$d" in /*) ;; *) d="$nginx_dir/$d" ;; esac
            http_dir=$d; break ;;
    esac
done
set +f
[ -n "$http_dir" ] || die "no 'include <dir>/*.conf' inside http {} of $nginx_conf; add 'include $nginx_dir/turbo/turbo-http.conf;' to http {} yourself"

nginx_user=$(sed -n 's/^[[:space:]]*user[[:space:]]\{1,\}\([^ ;]*\).*/\1/p' "$nginx_conf" | head -1)
if [ -z "$nginx_user" ]; then
    for u in www-data nginx http nobody; do id "$u" >/dev/null 2>&1 && { nginx_user=$u; break; }; done
fi

say "nginx config: $nginx_conf (http includes: $http_dir, user: ${nginx_user:-?})"
[ "$dry" = 1 ] || { mkdir -p "$nginx_dir/turbo"; : > "$manifest.new"; manifest="$manifest.new"; }

sed "s#/etc/nginx/turbo/#$nginx_dir/turbo/#g" "$here/nginx/turbo-http.conf" | put - "$nginx_dir/turbo/turbo-http.conf"
# Refresh-on-update secret (kept across reinstalls). WordPress needs the same
# value: see the message printed at the end.
if [ -f "$nginx_dir/turbo/refresh/site.map" ]; then
    refresh_secret=$(sed -n 's/^"~^\([A-Za-z0-9_-]*\)\$".*/\1/p' "$nginx_dir/turbo/refresh/site.map")
else
    refresh_secret=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    printf '"~^%s$" 1;\n' "$refresh_secret" | put - "$nginx_dir/turbo/refresh/site.map"
    [ "$dry" = 1 ] || chmod 600 "$nginx_dir/turbo/refresh/site.map"
fi
sed "s/fastcgi_cache_valid 200 301 302 [0-9smhd]*;/fastcgi_cache_valid 200 301 302 $ttl;/" \
    "$here/nginx/turbo-php-cache.conf" | put - "$nginx_dir/turbo/turbo-php-cache.conf"
sed "s#/etc/nginx/turbo/#$nginx_dir/turbo/#g" "$here/nginx/turbo-wordpress.conf" \
    | put - "$nginx_dir/turbo/turbo-wordpress.conf"
printf '# nexcore-turbo (see %s/turbo/)\ninclude %s/turbo/turbo-http.conf;\n' "$nginx_dir" "$nginx_dir" \
    | put - "$http_dir/00-turbo-http.conf"
run mkdir -p /var/cache/nginx/turbo
[ -n "$nginx_user" ] && run chown "$nginx_user" /var/cache/nginx/turbo
run chmod 700 /var/cache/nginx/turbo

php_ini_dirs=""; php_pool_dirs=""
if [ "$php" = 1 ]; then
    for d in /etc/php/*/fpm/conf.d /etc/php.d /etc/php[0-9]*/conf.d /etc/opt/remi/php*/php.d /usr/local/etc/php/conf.d; do
        [ -d "$d" ] && php_ini_dirs="$php_ini_dirs $d"
    done
    for d in /etc/php/*/fpm/pool.d /etc/php-fpm.d /etc/php[0-9]*/php-fpm.d /etc/opt/remi/php*/php-fpm.d /usr/local/etc/php-fpm.d; do
        [ -d "$d" ] && php_pool_dirs="$php_pool_dirs $d"
    done
    [ -n "$php_ini_dirs" ] || say "no PHP conf.d found; skipping PHP (use --no-php to silence)"
    for d in $php_ini_dirs; do
        put "$here/php/turbo-opcache.ini" "$d/99-turbo-opcache.ini"
        [ "$jit" = 1 ] && put "$here/php/turbo-jit.ini" "$d/99-turbo-jit.ini"
    done
    for d in $php_pool_dirs; do
        # Only override a pool that is actually called [www].
        if grep -qs '^\[www\]' "$d"/*.conf; then
            put "$here/php/turbo-fpm.conf" "$d/zz-turbo.conf"
        else
            say "no [www] pool in $d; leaving PHP-FPM process settings alone"
        fi
    done
fi

if [ "$dry" = 1 ]; then say "dry run finished; nothing written"; exit 0; fi

if ! nginx -t >/tmp/turbo-nginx-t.$$ 2>&1; then
    cat /tmp/turbo-nginx-t.$$ >&2; rm -f /tmp/turbo-nginx-t.$$
    say "nginx -t failed; rolling back"
    while read -r f; do rm -f "$f"; done < "$manifest"
    rm -f "$manifest"
    exit 1
fi
rm -f /tmp/turbo-nginx-t.$$
[ -f "$nginx_dir/turbo/.installed" ] && cat "$nginx_dir/turbo/.installed" >> "$manifest"
sort -u "$manifest" > "$nginx_dir/turbo/.installed"; rm -f "$manifest"

if [ "$reload" = 1 ]; then
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl reload nginx
        for s in $(systemctl list-units --type=service --no-legend 'php*-fpm*' 2>/dev/null | awk '{print $1}'); do
            systemctl reload "$s"
        done
    else
        nginx -s reload
        pkill -USR2 -f 'php-fpm: master' 2>/dev/null || true
    fi
    say "reloaded nginx and php-fpm"
fi

say "installed. Next: add to your server{} block"
say "    set \$turbo_php_upstream unix:/path/to/php-fpm.sock;"
say "    include $nginx_dir/turbo/turbo-wordpress.conf;"
say "then: nginx -t && reload nginx${php_ini_dirs:+ and php-fpm}"
say ""
say "WordPress: copy wordpress/nexcore-turbo-refresh.php to wp-content/mu-plugins/ and add to wp-config.php:"
say "    define('TURBO_REFRESH_SECRET', '$refresh_secret');"
say "    define('TURBO_REFRESH_URL', 'http://127.0.0.1');   // how this server reaches nginx"
