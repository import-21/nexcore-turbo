#!/bin/sh
# Adds one site to the python multi-site stack.
#   sh add-site.sh <name> [--domain example.test] [--from DIR --wsgi module:attr] [--posts N] [--no-reload]
# Without --from the site is the demo blog (docker/python-multisite/demo).
# --from DIR copies a project (manage.py at its top); migrate and collectstatic
# run when manage.py exists. Extra packages: put a requirements.txt in DIR.
# --no-reload: let the caller send one reload for many sites (bulk adds).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
name=${1:-}; shift || true
domain=localhost; from=""; wsgi=blog.wsgi:application; posts=0; reload=1
while [ $# -gt 0 ]; do
    case "$1" in
        --domain) shift; domain=$1 ;;
        --from) shift; from=$1 ;;
        --wsgi) shift; wsgi=$1 ;;
        --posts) shift; posts=$1 ;;
        --no-reload) reload=0 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
case "$name" in
    ""|*[!a-z0-9-]*|-*) echo "site name must be lowercase letters, digits and '-'" >&2; exit 2 ;;
esac
[ ${#name} -le 41 ] || { echo "site name too long" >&2; exit 2; }
case "$posts" in ""|*[!0-9]*) echo "--posts must be a number" >&2; exit 2 ;; esac
case "$wsgi" in ""|*[!A-Za-z0-9_.:]*) echo "--wsgi must look like module.path:attr" >&2; exit 2 ;; esac
case "$domain" in ""|*[!A-Za-z0-9.-]*) echo "invalid --domain" >&2; exit 2 ;; esac
[ -z "$from" ] || [ -d "$from" ] || { echo "--from $from is not a directory" >&2; exit 2; }

dc() { docker compose -f "$here/compose.yml" "$@"; }
app() { dc exec -T app "$@"; }
d=/srv/sites/$name
if app test -e "$d"; then echo "site $name already exists" >&2; exit 1; fi

# Each site gets its own uid (no passwd entry needed): next free number from 20001.
uid=$(app sh -c 'n=20000; for s in /srv/sites/*/; do [ -d "$s" ] || continue; u=$(stat -c %u "$s"); [ "$u" -gt "$n" ] && n=$u; done; echo $((n + 1))')
secret=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
refresh=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')

app sh -c "set -e; umask 077; mkdir -p $d.new/app $d.new/lib $d.new/data $d.new/static
    [ -n '$from' ] || cp -a /opt/turbo-demo/. $d.new/app/
    cat > $d.new/turbo.env <<ENV
TURBO_WSGI=$wsgi
DJANGO_SECRET_KEY=$secret
DJANGO_ALLOWED_HOSTS=$name.$domain
DJANGO_DATA=$d/data
DJANGO_STATIC_ROOT=$d/static
TURBO_REFRESH_URL=http://nginx
TURBO_REFRESH_HOST=$name.$domain
TURBO_REFRESH_SECRET=$refresh
ENV"
[ -z "$from" ] || tar -C "$from" -cf - . | app tar -C "$d.new/app" -xf - --no-same-owner
app sh -c "set -e; chown -R $uid:$uid $d.new; chmod 711 $d.new; chmod 700 $d.new/app $d.new/lib $d.new/data; chmod 755 $d.new/static; chmod 600 $d.new/turbo.env
    mv $d.new $d"

run() { app python -m nexcore_turbo.multisite run "$name" "$@"; }
if app test -f "$d/app/requirements.txt"; then
    run pip install -q --disable-pip-version-check --no-cache-dir --target "$d/lib" -r "$d/app/requirements.txt"
fi
if app test -f "$d/app/manage.py"; then
    run python manage.py migrate --noinput -v0
    run python manage.py collectstatic --noinput -v0
fi
[ "$posts" -gt 0 ] && run python manage.py seed "$posts"

# Refresh-on-update secret, known only to the site and nginx.
app sh -c "printf '\"~^%s\\\\.[^|]*\\\\|%s\$\" 1;\\n' '$name' '$refresh' > /srv/refresh/$name.map && chmod 644 /srv/refresh/$name.map"

[ "$reload" = 1 ] || exit 0
app sh -c "kill -HUP 1"
dc exec -T nginx nginx -s reload >/dev/null 2>&1
i=0; until app test -S "/run/turbo/$name.sock"; do
    i=$((i + 1)); [ $i -gt 50 ] && { echo "site socket did not appear" >&2; exit 1; }; sleep 0.2
done
echo "site $name: http://$name.$domain"
