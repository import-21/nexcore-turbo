#!/bin/sh
# Runs from the nginx image's /docker-entrypoint.d before nginx starts.
# Copies the read-only configs from /opt/turbo into place and tunes them:
#  - TURBO_CACHE_TTL: page cache lifetime (default 60s)
#  - worker_processes follows the container CPU limit (cgroup v1/v2), not the host
#    (override with TURBO_NGINX_WORKERS)
set -eu

src=/opt/turbo
ttl="${TURBO_CACHE_TTL:-60s}"
case "$ttl" in
    ""|*[!0-9smhd]*) echo "40-turbo-tune: invalid TURBO_CACHE_TTL '$ttl'" >&2; exit 1 ;;
esac

mkdir -p /etc/nginx/turbo /var/cache/nginx/turbo
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
