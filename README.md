# nexcore-turbo

**Make small servers serve a lot more.** Tested, conservative defaults that put
an nginx page cache in front of WordPress / PHP, tune OPcache and PHP-FPM, and
let gunicorn workers share one warmed-up copy of a Django or Flask app.

小さなサーバーで、もっと多くをさばくための設定集です。WordPress / PHP の前に
nginx のページキャッシュを置き、OPcache と PHP-FPM を調整し、Django / Flask を
gunicorn の全ワーカーで共有して動かします。日本語の説明は [下](#日本語) にあります。

| Part | What it does | Measured on 2 CPU / 2 GB |
|---|---|---|
| `nginx/` | Page cache for anonymous visitors (logged-in users, carts, POST, admin, API, query strings and anything that sets a cookie are never cached) | WordPress **34 → ~29,000 req/s** (cached pages) |
| `php/` | OPcache for PHP 7.2+ (still picks up file edits within 2 s) + optional JIT + PHP-FPM pool | WordPress container **534 MB → 130 MB** |
| `python/` | gunicorn config: preload, render your pages once before forking, close DB sockets, freeze the GC | private memory per worker **-59 to -81 %** |

The numbers come from `bench/run.sh` and the test suites below; see
[Benchmarks](#benchmarks) for the exact conditions and what they do **not** mean.

## Quick start

### WordPress with Docker

```sh
cd docker/wordpress
cp .env.example .env        # set DB_PASSWORD
docker compose up -d        # http://localhost:8080
# optional JIT: docker compose -f compose.yml -f compose.jit.yml up -d
```

`curl -I http://localhost:8080/` shows `X-Turbo-Cache: MISS`, then `HIT`.

### Existing server (nginx + PHP-FPM from your distribution)

```sh
sudo sh native/install.sh --dry-run   # see what would be written
sudo sh native/install.sh             # runs nginx -t, rolls back on failure
```

Then add to your site's `server {}` block and reload:

```nginx
set $turbo_php_upstream unix:/run/php/php8.3-fpm.sock;   # your PHP-FPM socket
include /etc/nginx/turbo/turbo-wordpress.conf;
```

Already have your own PHP location? Include only the cache part inside it:
`include /etc/nginx/turbo/turbo-php-cache.conf;`
Remove everything with `sudo sh native/install.sh --uninstall`.

### Django / Flask with gunicorn

```sh
pip install ./python
TURBO_WARMUP_PATHS="/,/about/,/blog/" TURBO_WARMUP_HOST=example.com \
  gunicorn -c python:nexcore_turbo.gunicorn_conf myproject.wsgi
```

| Variable | Default | |
|---|---|---|
| `TURBO_BIND` | `0.0.0.0:8000` | |
| `TURBO_WORKERS` | CPUs available to the container | respects `--cpus` and cpusets |
| `TURBO_WARMUP_PATHS` / `TURBO_WARMUP_FILE` | none | GET-only pages to render before forking |
| `TURBO_WARMUP_HOST` | `localhost` | must be in `ALLOWED_HOSTS` |
| `TURBO_AFTER_WARMUP` | none | `module:function` to close your own pools |
| `TURBO_DISABLE` | | `1` = plain gunicorn behaviour |

Django database connections and caches are closed after the warm-up so that no
socket is shared between workers. If you open other connections at import time
(SQLAlchemy engines, Redis clients, ...), close them in `TURBO_AFTER_WARMUP`.

## What gets cached, and what never does

Cached for `TURBO_CACHE_TTL` (default 60 s): `GET`/`HEAD` without a query string,
from visitors without a login/comment/cart/session cookie, whose response is a
200/301/302 (404 for 10 s) and does **not** set a cookie or say `private`,
`no-store` or `no-cache`.

Never cached: `POST` and other methods, `wp-admin`, `wp-login.php`, `wp-json`,
`xmlrpc.php`, `wp-cron.php`, cart/checkout/my-account, feeds, sitemaps, requests
with `Authorization`, and cookies `wordpress_logged_in_*`, `wp-postpass_*`,
`comment_author_*`, WooCommerce/EDD cart cookies and `PHPSESSID`.

Trade-offs to know:
- A published change can take up to the TTL to appear for anonymous visitors
  (the first visitor after expiry may still get the old copy while nginx
  refreshes it in the background).
- The cache key includes scheme, method, host and full URI, so sites never
  share entries.
- Pages that personalise content for anonymous visitors **without** a cookie
  (e.g. by IP or `User-Agent`) must send `Cache-Control: private`.

## Tested environments

Every change is checked by three suites (all in `tests/`):

- `tests/wp/` – full Docker stack, real WordPress installed with wp-cli:
  cache hit/miss/bypass rules, login, comments, post updates, plugin install,
  OPcache revalidation, upload/PHP execution rules, restart.
- `tests/native/` – `native/install.sh` on stock distribution packages, with
  dry-run, rollback on a broken nginx config, and uninstall.
- `tests/python/` – real gunicorn: warm-up, per-worker DB connections
  (PostgreSQL), 480 concurrent requests, SIGHUP reload, CPU-limit detection,
  memory saving vs. plain gunicorn.

Last full run: 2026-10-25. Every row below passed every check.

**Docker stack (`tests/wp`, 55-56 checks each)**

| WordPress image | nginx | Database | |
|---|---|---|---|
| php7.4-fpm-alpine (WP 6.1) | 1.24-alpine | MariaDB 10.6 | |
| php8.1-fpm-alpine | 1.24-alpine | MariaDB 10.11 | |
| 6.4-php8.1-fpm-alpine | 1.25-alpine | MySQL 8.0 | older WordPress |
| php8.2-fpm (Debian) | 1.26 | MySQL 8.0 | |
| php8.3-fpm-alpine | 1.26-alpine | MariaDB 11.4 | |
| php8.3-fpm (Debian) | 1.27 | MariaDB 11.4 | |
| php8.3-fpm-alpine | mainline-alpine | MariaDB LTS | JIT |
| php8.4-fpm-alpine | 1.27-alpine | MySQL 8.4 | |
| php8.4-fpm-alpine | 1.26-alpine | MariaDB 11.4 | JIT |
| php8.3-fpm-alpine on **arm64** (QEMU) | 1.26-alpine | MariaDB 11.4 (x86_64) | nginx + PHP on arm64 |

**Existing servers (`tests/native`, 28 checks each)** – stock packages only

| Distribution | nginx | PHP |
|---|---|---|
| Ubuntu 22.04 | 1.18.0 | 8.1 |
| Ubuntu 24.04 | 1.24.0 | 8.3 |
| Debian 12 | 1.22.1 | 8.2 |
| Debian 13 | 1.26.3 | 8.4 |
| Rocky Linux 8 | 1.14.1 | 7.2 |
| Rocky Linux 9 | 1.20.1 | 8.0 |
| AlmaLinux 10 | 1.26.3 | 8.3 |
| Fedora 42 | 1.30.1 | 8.4 |
| Amazon Linux 2023 | 1.30.5 | 8.5 |
| Alpine 3.20 | 1.26.3 | 8.3 |
| Alpine 3.22 | 1.28.3 | 8.4 |
| Debian 12 on **arm64** (QEMU) | 1.22.1 | 8.2 |

**Python (`tests/python`, 13-15 checks each)**

| Python | Framework | gunicorn | Database | Memory per worker |
|---|---|---|---|---|
| 3.8 | Django 4.2 | 20.1 | SQLite | -66 % |
| 3.9 | Django 4.2 | 21.2 | PostgreSQL 16 | -66 % |
| 3.10 | Django 5.2 | 22.0 | PostgreSQL 16 | -59 % |
| 3.11 (`--cpus 1.5`) | Django 5.2 | 23.0 | SQLite | -69 % |
| 3.12 Alpine (musl) | Django 6.1 | 26.2 | PostgreSQL 16 | -67 % |
| 3.13 | Django 6.1 | 26.2 | PostgreSQL 16 | -66 % |
| 3.14 | Django 6.1 | 26.2 | SQLite | -66 to -78 % |
| 3.8 | Flask 2.2 | 20.1 | – | -62 % |
| 3.12 Alpine (musl) | Flask 3 | 26.2 | – | -71 % |
| 3.14 (`--cpus 0.5`) | Flask 3 | 26.2 | – | -68 % |
| 3.12 on **arm64** (QEMU) | Django 6.1 | 26.2 | SQLite | -66 % |

Hosts: Linux (cgroup v2) with Docker (upstream and distribution packages).
arm64 was tested under QEMU emulation, not
on real ARM hardware. Not covered yet: cgroup v1 hosts, Podman,
macOS/Windows Docker Desktop, Apache in front of PHP, LiteSpeed.

## Benchmarks

`bench/run.sh` boxes the official `wordpress:php8.3-apache` image and the turbo
stack into the same 2 CPUs / 2 GB, generates the same posts on the default
theme, and runs k6 with 50 virtual users for 30 s, five times.

Run on 2026-10-24, stack pinned to 2 cores of a many-core x86_64 host, load
generator on separate cores ([raw output](docs/bench-2026-10-24.txt)):

| | Official image | nexcore-turbo |
|---|---|---|
| Requests per second (5 rounds) | 33.5 – 34.4 | 28,510 – 30,256 |
| p95 response time | 1.55 – 1.66 s | 3.0 – 3.5 ms |
| Memory (WordPress / nginx / DB) | 534 MB / – / 113 MB | 130 MB / 14 MB / 93 MB |
| Errors | 0 | 0 |

Worst round against best round: **28,510 / 34.41 = 828x**.

These numbers describe cached page views for anonymous visitors on that box.
They do not apply to logged-in users, form posts or carts, and real-world
speed depends on the site and the network.

## License

MIT

---

## 日本語

### これは何か

小さなサーバー（2コア・2GB程度）でも、WordPress や Django を多くの訪問者に
速く返せるようにする、テスト済みの設定一式です。新しい仕組みを発明したもの
ではなく、定番の手法（nginx のページキャッシュ、OPcache、gunicorn の preload）を
**安全側の初期値で組み合わせ、壊れないことを自動テストで確かめた**ものです。

### 安全のために決めていること

- ログイン中・コメント投稿者・カートを持つ人・セッションを持つ人には、キャッシュを使いません。
- 管理画面、ログイン、API、フォーム送信、検索などクエリ付きのURLは、常にその場で作ります。
- Cookie を発行するページ、`private`・`no-store`・`no-cache` を返すページは保存しません。
- サイトが違えば（ホスト名が違えば）キャッシュは混ざりません。
- プラグインの更新やファイルの編集は、PHP の再起動なしで 2 秒以内に反映されます。
- アップロードフォルダの PHP は実行されません。
- 既存サーバー用のインストーラーは `nginx -t` に失敗したら元に戻します。サイトの設定ファイルは書き換えません。

### 使い方

**Docker で WordPress を動かす**

```sh
cd docker/wordpress
cp .env.example .env        # DB_PASSWORD を設定
docker compose up -d        # http://localhost:8080
```

**今あるサーバー（nginx + PHP-FPM）に入れる**

```sh
sudo sh native/install.sh --dry-run   # 何が書き込まれるか確認
sudo sh native/install.sh             # nginx -t に失敗したら自動で元に戻す
```

そのあと、サイトの `server {}` に次の2行を足して nginx を再読み込みします。

```nginx
set $turbo_php_upstream unix:/run/php/php8.3-fpm.sock;   # PHP-FPM のソケット
include /etc/nginx/turbo/turbo-wordpress.conf;
```

元に戻すときは `sudo sh native/install.sh --uninstall` です。

**Django / Flask（gunicorn）**

```sh
pip install ./python
TURBO_WARMUP_PATHS="/,/about/" TURBO_WARMUP_HOST=example.com \
  gunicorn -c python:nexcore_turbo.gunicorn_conf myproject.wsgi
```

起動時に指定したページを1回表示してから全ワーカーに分けるので、テンプレートや
読み込んだモジュールを全ワーカーで共有できます。Django の DB 接続は分ける前に
自動で閉じます。独自に作った接続（SQLAlchemy、Redis など）は
`TURBO_AFTER_WARMUP` で閉じてください。

### 注意

- 記事を更新してから、ログインしていない訪問者に反映されるまで、最大で TTL（初期値60秒）かかります。
- Cookie を使わずに訪問者ごとに内容を変えるページ（IPアドレスで出し分けるなど）は、`Cache-Control: private` を返してください。
- 速度の数字は、ログインしていない訪問者がキャッシュ済みのページを見る場合のものです。
