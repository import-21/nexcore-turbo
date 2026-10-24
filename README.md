# nexcore-turbo

**小さなサーバーで、もっと多くの訪問者をさばくための設定集です。**
WordPress / PHP の前に nginx のページキャッシュを置き、OPcache と PHP-FPM を調整し、
Django / Flask のアプリを gunicorn の全ワーカーで共有して動かします。

新しい仕組みを発明したものではありません。nginx のページキャッシュ、OPcache、
gunicorn の preload といった定番の手法を**安全側の初期値で組み合わせ、壊れないことを
自動テストで確かめた**ものです。

| 部品 | 内容 | 2コア・2GB での実測 |
|---|---|---|
| `nginx/` | ログインしていない訪問者向けのページキャッシュ（ログイン中・カート・POST・管理画面・API・クエリ付きURL・Cookie を発行するページはキャッシュしない） | WordPress **毎秒34件 → 約29,000件**（キャッシュ済みページ） |
| `php/` | PHP 7.2 以降向けの OPcache（ファイルの編集は2秒以内に反映）、JIT（任意）、PHP-FPM のプール設定 | WordPress コンテナのメモリ **534MB → 130MB** |
| `python/` | gunicorn 設定：preload、ワーカーを分ける前にページを1回表示、DB 接続を閉じる、GC を固定 | ワーカー1つあたりのメモリ **59〜81% 減** |

数字は `bench/run.sh` と下記のテストで測ったものです。測定条件と、数字が
**意味しないこと**は [ベンチマーク](#ベンチマーク) を見てください。

## 使い方

### Docker で WordPress を動かす

```sh
cd docker/wordpress
cp .env.example .env        # DB_PASSWORD を設定
docker compose up -d        # http://localhost:8080
# JIT を使う場合: docker compose -f compose.yml -f compose.jit.yml up -d
```

`curl -I http://localhost:8080/` を2回実行すると、`X-Turbo-Cache` が `MISS` → `HIT` になります。

### 今あるサーバー（ディストリビューションの nginx + PHP-FPM）に入れる

```sh
sudo sh native/install.sh --dry-run   # 何が書き込まれるか確認（何も変更しない）
sudo sh native/install.sh             # nginx -t に失敗したら自動で元に戻す
```

そのあと、サイトの `server {}` に次の2行を足して nginx を再読み込みします。

```nginx
set $turbo_php_upstream unix:/run/php/php8.3-fpm.sock;   # PHP-FPM のソケット
include /etc/nginx/turbo/turbo-wordpress.conf;
```

PHP 用の `location` を自分で書いている場合は、その中にキャッシュ部分だけを入れることもできます。
`include /etc/nginx/turbo/turbo-php-cache.conf;`

元に戻すときは `sudo sh native/install.sh --uninstall` です。

| オプション | 内容 |
|---|---|
| `--dry-run` | 書き込む予定のファイルを表示するだけ |
| `--ttl 60s` | キャッシュの有効期限 |
| `--jit` | PHP の JIT も有効にする |
| `--no-php` | nginx の設定だけ入れる |
| `--reload` | 入れたあと nginx と PHP-FPM を再読み込みする |
| `--uninstall` | 入れたファイルをすべて削除する |

### Django / Flask（gunicorn）

```sh
pip install ./python
TURBO_WARMUP_PATHS="/,/about/,/blog/" TURBO_WARMUP_HOST=example.com \
  gunicorn -c python:nexcore_turbo.gunicorn_conf myproject.wsgi
```

起動時に指定したページを1回表示してからワーカーに分けるので、テンプレートや
読み込んだモジュールを全ワーカーで共有できます。

| 環境変数 | 初期値 | 説明 |
|---|---|---|
| `TURBO_BIND` | `0.0.0.0:8000` | 待ち受けるアドレス |
| `TURBO_WORKERS` | コンテナで使える CPU 数 | `--cpus` や cpuset の制限に従う |
| `TURBO_WARMUP_PATHS` / `TURBO_WARMUP_FILE` | なし | ワーカーを分ける前に表示するページ（GET のみ） |
| `TURBO_WARMUP_HOST` | `localhost` | `ALLOWED_HOSTS` に含まれるホスト名にする |
| `TURBO_AFTER_WARMUP` | なし | 独自の接続を閉じる関数（`モジュール:関数`） |
| `TURBO_DISABLE` | | `1` で通常の gunicorn と同じ動作に戻す |

Django の DB 接続とキャッシュは、ウォームアップの後に自動で閉じます（ワーカー間で
接続を共有しないため）。読み込み時に独自の接続（SQLAlchemy、Redis など）を作っている
場合は、`TURBO_AFTER_WARMUP` で閉じてください。

## キャッシュするもの・しないもの

**キャッシュする**（有効期限 `TURBO_CACHE_TTL`、初期値60秒）：クエリ文字列のない
`GET`/`HEAD` で、ログイン・コメント・カート・セッションの Cookie を持たない訪問者への、
200/301/302 の応答（404 は10秒）。ただし Cookie を発行する応答と、`private`・`no-store`・
`no-cache` を返す応答は保存しません。

**キャッシュしない**：
- `POST` などの GET/HEAD 以外のリクエスト
- `wp-admin`、`wp-login.php`、`wp-json`、`xmlrpc.php`、`wp-cron.php`
- カート・購入手続き・マイアカウント、フィード、サイトマップ
- `Authorization` ヘッダー付きのリクエスト
- Cookie `wordpress_logged_in_*`、`wp-postpass_*`、`comment_author_*`、WooCommerce/EDD のカート、`PHPSESSID` を持つ訪問者

**知っておくこと**：
- 記事を更新してから、ログインしていない訪問者に反映されるまで最大で TTL かかります（期限切れ直後の1人目には、裏で更新している間だけ古いページが返ることがあります）。
- キャッシュのキーにはスキーム・メソッド・ホスト名・URL 全体を含むので、サイト同士で混ざりません。
- Cookie を使わずに訪問者ごとに内容を変えるページ（IP アドレスや `User-Agent` で出し分けるなど）は、`Cache-Control: private` を返してください。
- アップロードフォルダの PHP は実行されません。ドットファイル（`.env`、`.git` など）は配信しません。

## テスト済みの環境

変更のたびに、`tests/` の3種類のテストで確認しています。

- `tests/wp/`：Docker 構成に wp-cli で本物の WordPress を入れ、キャッシュの HIT/MISS/BYPASS、ログイン、コメント、記事更新、プラグイン導入、OPcache の再読み込み、アップロードと PHP 実行の制限、再起動を確認
- `tests/native/`：各ディストリビューション標準のパッケージに `native/install.sh` を入れ、dry-run、壊れた nginx 設定での自動ロールバック、アンインストールまで確認
- `tests/python/`：本物の gunicorn で、ウォームアップ、ワーカーごとの DB 接続（PostgreSQL）、480件の同時リクエスト、SIGHUP での再読み込み、CPU 制限の検出、通常の gunicorn とのメモリ比較を確認

最終実行：2026-10-25。下の表のすべての環境で、全項目が通過しています。

**Docker 構成（`tests/wp`、各55〜56項目）**

| WordPress イメージ | nginx | データベース | 備考 |
|---|---|---|---|
| php7.4-fpm-alpine（WP 6.1） | 1.24-alpine | MariaDB 10.6 | |
| php8.1-fpm-alpine | 1.24-alpine | MariaDB 10.11 | |
| 6.4-php8.1-fpm-alpine | 1.25-alpine | MySQL 8.0 | 古い WordPress |
| php8.2-fpm（Debian） | 1.26 | MySQL 8.0 | |
| php8.3-fpm-alpine | 1.26-alpine | MariaDB 11.4 | |
| php8.3-fpm（Debian） | 1.27 | MariaDB 11.4 | |
| php8.3-fpm-alpine | mainline-alpine | MariaDB LTS | JIT |
| php8.4-fpm-alpine | 1.27-alpine | MySQL 8.4 | |
| php8.4-fpm-alpine | 1.26-alpine | MariaDB 11.4 | JIT |
| php8.3-fpm-alpine（**arm64**、QEMU） | 1.26-alpine | MariaDB 11.4（x86_64） | nginx と PHP を arm64 で実行 |

**既存サーバー（`tests/native`、各28項目）**：標準パッケージのみ使用

| ディストリビューション | nginx | PHP |
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
| Debian 12（**arm64**、QEMU） | 1.22.1 | 8.2 |

**Python（`tests/python`、各13〜15項目）**

| Python | フレームワーク | gunicorn | データベース | ワーカーのメモリ |
|---|---|---|---|---|
| 3.8 | Django 4.2 | 20.1 | SQLite | 66% 減 |
| 3.9 | Django 4.2 | 21.2 | PostgreSQL 16 | 66% 減 |
| 3.10 | Django 5.2 | 22.0 | PostgreSQL 16 | 59% 減 |
| 3.11（`--cpus 1.5`） | Django 5.2 | 23.0 | SQLite | 69% 減 |
| 3.12 Alpine（musl） | Django 6.1 | 26.2 | PostgreSQL 16 | 67% 減 |
| 3.13 | Django 6.1 | 26.2 | PostgreSQL 16 | 66% 減 |
| 3.14 | Django 6.1 | 26.2 | SQLite | 66〜78% 減 |
| 3.8 | Flask 2.2 | 20.1 | – | 62% 減 |
| 3.12 Alpine（musl） | Flask 3 | 26.2 | – | 71% 減 |
| 3.14（`--cpus 0.5`） | Flask 3 | 26.2 | – | 68% 減 |
| 3.12（**arm64**、QEMU） | Django 6.1 | 26.2 | SQLite | 66% 減 |

テストしたホスト：Linux（cgroup v2）+ Docker（公式版とディストリビューション版）。
arm64 は QEMU のエミュレーションでの
確認で、ARM の実機では試していません。

まだ試していない環境：cgroup v1 のホスト、Podman、macOS/Windows の Docker Desktop、
Apache を PHP の前に置く構成、LiteSpeed。

## ベンチマーク

`bench/run.sh` は、公式の `wordpress:php8.3-apache` イメージと nexcore-turbo を同じ
2コア・2GB に閉じ込め、標準テーマで同じ記事を作り、k6 で50人の同時アクセスを30秒×5回かけます。

2026-10-24 実施。多コアの x86_64 サーバーで2コアに固定し、負荷をかける側は別のコアで
動かしました（[生の出力](docs/bench-2026-10-24.txt)）。

| | 公式イメージ | nexcore-turbo |
|---|---|---|
| 1秒あたりの処理件数（5回） | 33.5〜34.4 | 28,510〜30,256 |
| 応答時間（95%値） | 1.55〜1.66秒 | 3.0〜3.5ミリ秒 |
| メモリ（WordPress / nginx / DB） | 534MB / – / 113MB | 130MB / 14MB / 93MB |
| エラー | 0 | 0 |

最も不利な組み合わせ（nexcore-turbo の最低値 ÷ 公式イメージの最高値）：**28,510 ÷ 34.41 = 828倍**

この数字は、ログインしていない訪問者がキャッシュ済みのページを見る場合のものです。
ログイン中の操作、フォーム送信、カートには当てはまりません。実際の速度はサイトの内容や
通信環境によって変わります。

## ライセンス

MIT
