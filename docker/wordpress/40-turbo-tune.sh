#!/bin/sh
# Runs from the nginx image's /docker-entrypoint.d before nginx starts.
# Copies the read-only configs from /opt/turbo into place and tunes them:
#  - TURBO_CACHE_TTL: page cache lifetime (default 60s)
#  - worker_processes follows the container CPU limit (cgroup v1/v2), not the host
#    (override with TURBO_NGINX_WORKERS)
#  - TURBO_REFRESH_SECRET: secret for refresh-on-update (see wordpress/)
set -eu

src=/opt/turbo
ttl="${TURBO_CACHE_TTL:-60s}"
case "$ttl" in
    ""|*[!0-9smhd]*) echo "40-turbo-tune: invalid TURBO_CACHE_TTL '$ttl'" >&2; exit 1 ;;
esac

mkdir -p /etc/nginx/turbo/refresh /var/cache/nginx/turbo
secret="${TURBO_REFRESH_SECRET:-}"
if [ -n "$secret" ]; then
    case "$secret" in *[!A-Za-z0-9_-]*) echo "40-turbo-tune: TURBO_REFRESH_SECRET may only contain A-Z a-z 0-9 _ -" >&2; exit 1 ;; esac
    # 16-40 characters: longer keys do not fit nginx's default map hash bucket.
    [ ${#secret} -ge 16 ] && [ ${#secret} -le 40 ] || { echo "40-turbo-tune: TURBO_REFRESH_SECRET must be 16-40 characters" >&2; exit 1; }
    # The directory is read-only when the multi-site stack mounts per-site secrets there.
    if [ -w /etc/nginx/turbo/refresh ]; then
        printf '"~^%s$" 1;\n' "$secret" > /etc/nginx/turbo/refresh/env.map
    fi
fi
cp "$src/turbo-http.conf" "$src/turbo-wordpress.conf" /etc/nginx/turbo/
sed "s/fastcgi_cache_valid 200 301 302 [0-9smhd]*;/fastcgi_cache_valid 200 301 302 $ttl;/" \
    "$src/turbo-php-cache.conf" > /etc/nginx/turbo/turbo-php-cache.conf

cpus=""
if [ -r /sys/fs/cgroup/cpu.max ]; then
    read -r quota period < /sys/fs/cgroup/cpu.max
    [ "$quota" != "max" ] && cpus=$(( (quota + period - 1) / period ))
elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
    quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
    period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
    [ "$quota" -gt 0 ] && cpus=$(( (quota + period - 1) / period ))
fi
[ -z "$cpus" ] && cpus=$(nproc 2>/dev/null || echo 1)
[ "$cpus" -lt 1 ] && cpus=1
cpus="${TURBO_NGINX_WORKERS:-$cpus}"
sed "s/^worker_processes .*;/worker_processes $cpus;/" "$src/nginx.conf" > /etc/nginx/nginx.conf
echo "40-turbo-tune: worker_processes=$cpus cache_ttl=$ttl"
