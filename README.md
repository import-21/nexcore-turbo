# nexcore-turbo

**同じ 2コア・2GB のサーバーに、WordPress や Django のサイトを10倍以上載せるための設定集です。**

| 2コア・2GB に載ったサイト数 | 従来の構成 | nexcore-turbo |
|---|---|---|
| **WordPress** 重い負荷（1サイト1日 約4万PV） | 14サイト | **150サイト**（約10.7倍） |
| **WordPress** 標準的な負荷（1サイト1日 約4,300PV） | 14サイト（メモリで頭打ち） | **400サイト**（約28倍） |
| **Django** 重い負荷（1サイト1日 約4万PV） | 26サイト | **600サイト**（約23倍） |
| **Django** 標準的な負荷（1サイト1日 約4,300PV） | 26サイト（メモリで頭打ち） | **1,000サイト以上**（約38倍以上。1,000で計測を打ち切り） |

従来の構成は、WordPress が「1サイト＝公式 WordPress コンテナ1つ」、Django が「1サイト＝コンテナ1つで gunicorn のワーカー2つ」です。
nexcore-turbo は WordPress が `docker/multisite`、Django が `docker/python-multisite` です。

合格条件はどちらも「エラー0件・応答時間の95%値が0.5秒以内・全コンテナのメモリ合計が2GB以内」です。
条件と生データは [収容数ベンチマーク](#収容数ベンチマーク) を見てください。

この表は 2026-10-25 の版で、デモのサイトを使い、ブラウザと違って gzip を要求しない計測方法で測ったものです。
その後の版ではキャッシュを圧縮済みで保存するようにしたため、ブラウザからの実際の速度はむしろ上がっていますが、
この表の現行版での測り直しはまだです。より重い Django アプリ（ブログ）での結果は [より重い Django アプリでの計測](#より重い-django-アプリでの計測) にあります。

従来の構成は、サイトごとに Apache と PHP（Django なら Python と gunicorn）が丸ごと動き、同じ WordPress 本体や
Django を別々に読み込むため、アクセスがなくても1サイト約130MB（Django は約75MB）を使います。nexcore-turbo は次の組み合わせで、
「同じものは1回だけ持つ・使っていないものは動かさない・同じ結果は作り直さない」ようにしています。

| 技術 | 効果 |
|---|---|
| nginx のページキャッシュ | ほとんどのアクセスで PHP も DB も動かない |
| 更新時だけ作り直す（`wordpress/nexcore-turbo-refresh.php`） | 記事・コメント・メニューの更新はすぐ反映。それ以外はキャッシュを長く使える |
| WordPress 本体を全サイトで1つだけ共有（読み取り専用） | OPcache のコンパイルが全サイトで1回 |
| PHP-FPM をサイトごとの ondemand プールに | アクセスのないサイトの PHP プロセスは0個 |
| nginx・PHP-FPM・MariaDB を全サイトで1つずつ | サイトを増やしても、増えるのはファイルと DB のテーブルだけ |
| ページを圧縮した状態でキャッシュ | キャッシュから返すたびに gzip で圧縮し直さない。重いブログアプリで、ブラウザと同じ条件で **毎秒4,309件 → 29,365件** |
| 広告・SNS の追跡パラメータ（`utm_*`・`fbclid` など）を外す | SNS や広告から来た訪問者にもキャッシュから返す。パラメータはアプリにも届かない |
| Django：アクセスのないサイトは止める（`nexcore_turbo.multisite`） | 最初のアクセスで約0.05秒で起動し、60秒使われなければ終了。待機中のサイトのメモリは0 |
| Django：Django 本体を読み込んだ1つのプロセスから各サイトを起動 | Django 本体（と Markdown・Pillow・Pygments があればそれも）のメモリを全サイトで共有 |
| Django：同時に動かすサイト数をメモリから自動で決める（`TURBO_MAX_ACTIVE=auto`） | 動いているサイトの実際の使用量から、予算に収まる数を決める。上限に達したら、いちばん長く使われていないサイトを止めて席を空ける |
| Django：サイトごとのメモリ・プロセス数・CPU の上限（cgroup v2、任意） | 1サイトの暴走（メモリの食いつぶし、fork 爆弾）で他のサイトが止まらない |

**サイト同士の分離**：Django はサイトごとに別の Linux ユーザーで動き、他のサイトの設定・データ・コード・ソケットに触れません（テストで確認済み）。
WordPress の複数サイト構成も、サイトごとに別の Linux ユーザー（3万番台）で PHP が動きます。他のサイトのファイル（`wp-config.php` の
DB パスワードを含む）を読めず、他のサイトの PHP の接続口にもつなげません。`open_basedir` を抜けられた場合も同じです。
一時ファイルとセッションはサイト専用のフォルダに置き、OPcache も読む権限のあるサイトにしか使わせません（テストで確認済み）。
2026-10-28 より前に作った複数サイト構成は、`sh isolate-sites.sh` で今あるサイトをこの形に移せます（何度実行しても同じ結果）。

新しい仕組みを発明したものではありません。定番の手法を**安全側の初期値で組み合わせ、壊れないことを
自動テストで確かめた**ものです。1サイト単位の高速化や、Django / Flask 向けの部品も入っています。

| 部品 | 内容 | 2コア・2GB での実測 |
|---|---|---|
| `docker/multisite/` | 多数の WordPress サイトを1組の nginx・PHP-FPM・MariaDB で動かす構成 | 上の表 |
| `docker/python-multisite/` | 多数の Django / Flask（WSGI）サイトを1組の nginx とサイトサーバーで動かす構成 | 上の表 |
| `nginx/` | ログインしていない訪問者向けのページキャッシュ（ログイン中・カート・POST・管理画面・API・クエリ付きURL・Cookie を発行するページはキャッシュしない） | 1サイトで **毎秒34件 → 約23,500件**（ブラウザと同じく gzip を要求） |
| `php/` | PHP 7.2 以降向けの OPcache（ファイルの編集は2秒以内に反映）、JIT（任意）、PHP-FPM のプール設定 | WordPress コンテナのメモリ **534MB → 130MB** |
| `python/` | gunicorn 設定：preload、ワーカーを分ける前にページを1回表示、DB 接続を閉じる、GC を固定 | ワーカー1つあたりのメモリ **59〜81% 減** |

## 使い方

### 多数のサイトを1台で動かす（ホスティング向け）

```sh
cd docker/multisite
cp .env.example .env              # DB_ROOT_PASSWORD を設定
docker compose up -d --build      # http://<サイト名>.<ドメイン>:8080
sh add-site.sh shop1 --domain example.com    # → http://shop1.example.com
sh purge-site.sh shop1                       # そのサイトのキャッシュを今すぐ全部消す
sh remove-site.sh shop1
```

- `<サイト名>.<任意のドメイン>` でアクセスすると、そのサイトが表示されます（DNS をこのサーバーに向けてください）。
- サイトの追加・削除は再起動なしで反映されます。
- 各サイトは自分の `wp-config.php` と `wp-content`（プラグイン・テーマ・アップロード）だけを持ちます。
  WordPress 本体の更新は、イメージを作り直して `docker compose up -d --build` するだけで全サイトに反映されます。
- 遅いリクエスト（5秒以上）は PHP のバックトレース付きで `docker compose logs php` に出ます。

### 多数の Django / Flask サイトを1台で動かす

```sh
cd docker/python-multisite
docker compose up -d --build                     # http://<サイト名>.<ドメイン>:8080
sh add-site.sh blog1 --domain example.com        # デモのブログ → http://blog1.example.com
sh add-site.sh shop --domain example.com --from ./myproject --wsgi myproject.wsgi:application
sh purge-site.sh shop                            # そのサイトのキャッシュを今すぐ全部消す
sh remove-site.sh shop
```

- `--from` のプロジェクトは `manage.py` があれば `migrate` と `collectstatic` を自動で実行し、`requirements.txt` があればそのサイト専用にインストールします。
- サイトごとに `/srv/sites/<サイト名>/turbo.env` があり、`DJANGO_SECRET_KEY`・`DJANGO_ALLOWED_HOSTS`・DB の場所などを環境変数として渡します（`TURBO_WSGI` は必須）。
- 各サイトは別々の Linux ユーザーで動き、他のサイトのコード・データ・設定を読めず、他のサイトのソケットにも接続できません。
- `manage.py` のコマンドは `docker compose exec app python -m nexcore_turbo.multisite run <サイト名> python manage.py <コマンド>` で、そのサイトのユーザーとして実行します。
- Django のバージョンは全サイト共通（イメージの `DJANGO` で指定）です。別のバージョンが必要なサイトは、別のスタックに分けてください。
- サイトごとのメモリ・プロセス数・CPU の上限（cgroup v2）は、ホストで一度 `turbo.slice` を作ってから有効にします
  （`compose.yml` のコメントに手順があります）。有効にしない場合も、プロセス数の上限（`RLIMIT_NPROC`）と
  サイト専用の一時フォルダは常に効いています。

| 環境変数 | 初期値 | 説明 |
|---|---|---|
| `TURBO_IDLE` | `60` | この秒数アクセスがなければサイトを止める |
| `TURBO_MAX_ACTIVE` | `auto` | 同時に動かすサイト数。`auto` は `TURBO_MEMORY_BUDGET` に収まる数を、動いているサイトの実際の使用量から決める。数字で固定もできる |
| `TURBO_MEMORY_BUDGET` | コンテナのメモリ上限（なければメモリの90%） | サイトとサイトサーバーが使ってよいメモリ（例 `1700M`。nginx の分は空けておく） |
| `TURBO_SITE_WORKERS` | `2` | サイトごとの gunicorn ワーカー数（上限 `TURBO_SITE_MAX_WORKERS`=4）。キャッシュできないページ（フォームなど）で後ろの訪問者が待たされないように |
| `TURBO_SITE_THREADS` | `1` | ワーカーごとのスレッド数（2以上で gthread。受け付けた要求がスレッドの空き待ちになるため、初期値は1） |
| `TURBO_SITE_TIMEOUT` | `30` | 1リクエストの制限時間。処理中のサイトは止めないが、この時間＋15秒を過ぎた処理中の数は取り残しとみなす |
| `TURBO_PRELOAD` | `django,gunicorn,markdown,PIL,pygments` | 最初に1回だけ読み込んで全サイトで共有するパッケージ（入っていないものは飛ばす） |
| `TURBO_CACHE_TTL` | `24h` | ページを保持する時間。更新時に作り直すので長くてよい |
| `TURBO_STRIP_TRACKING` | `1` | `0` にすると追跡パラメータを外さない（サーバー側で `utm_*` を読むサイト向け。クエリ付きはキャッシュされなくなる） |
| `TURBO_CGROUP`・`TURBO_SITE_MEMORY`・`TURBO_SITE_PIDS`・`TURBO_SITE_CPUS` | 無効・`512M`・`128`・`1` | サイトごとの上限（上の cgroup v2 の手順で有効にする） |

記事を保存したらキャッシュをすぐ作り直すには、`nexcore_turbo.refresh.refresh(["/", obj.get_absolute_url()])` を `post_save` などから呼びます（デモのブログに例があります）。

### Docker で WordPress を1サイト動かす

```sh
cd docker/wordpress
cp .env.example .env        # DB_PASSWORD と TURBO_REFRESH_SECRET を設定
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

**キャッシュする**：クエリ文字列のない（または追跡パラメータだけの）`GET`/`HEAD` で、Cookie を持たない
（または分析・同意記録など、ページの中身を変えない Cookie だけを持つ）訪問者への応答。200 は `TURBO_CACHE_TTL`（Docker 構成は24時間、既存サーバー向けは60秒）、
301/302 は60秒、404 は10秒です。ただし Cookie を発行する応答と、`private`・`no-store`・`no-cache` を返す応答は保存しません。

**追跡パラメータ**：クエリが `utm_*`・`fbclid`・`gclid`・`gbraid`・`wbraid`・`dclid`・`msclkid`・`yclid`・`twclid`・`ttclid`・
`igshid`・`li_fat_id`・`mc_cid`・`mc_eid`・`_gl` だけでできている場合は、キャッシュのキーからもアプリへのリクエストからも外し、
パラメータなしのページと同じキャッシュを返します（アナリティクスはブラウザ側で URL を読むので影響しません）。
他のパラメータが1つでも混ざっている、`;` で区切られている、名前が符号化されているなどの場合は外さず、今までどおりキャッシュしません。

**圧縮**：キャッシュするページは、アプリ（Python はサイトサーバー、PHP は `php/turbo-compress.php`）が1回だけ gzip で圧縮し、
圧縮したまま保存します。gzip を受け付けない訪問者には nginx が展開して返します。Cookie を発行するページ、
`private` のページ、200 以外の応答は圧縮しません（秘密の値を含みうるページを圧縮すると BREACH 攻撃の対象になるため）。

**キャッシュしない**：
- `POST` などの GET/HEAD 以外のリクエスト
- `wp-admin`、`wp-login.php`、`wp-json`、`xmlrpc.php`、`wp-cron.php`
- カート・購入手続き・マイアカウント、フィード、サイトマップ
- `Authorization` ヘッダー付きのリクエスト
- 上記以外の Cookie を1つでも持つ訪問者（ログイン・カート・セッション・言語・A/B テストなど、アプリがどんな名前の Cookie で中身を変えても、別の訪問者に渡らないように）。キャッシュを使い続けてよい Cookie は `_ga`・`_gid`・`_gat*`・`_gcl_*`・`_fbp`・`_fbc`・`_clck`・`_clsk`・`_hj*`・`_uetsid`・`_uetvid`・`cookieconsent_status`・`cookie_consent`・`CookieConsent`・`wordpress_test_cookie` だけです
- `/admin/`、`/accounts/`、`/api/` で始まる URL

**知っておくこと**：
- 記事・固定ページ・コメント・メニュー・サイト名・テーマを変更すると、`wordpress/nexcore-turbo-refresh.php`（Docker 構成では組み込み済み）がそのページとトップページ・カテゴリーをすぐ作り直します。プラグインを入れていない場合や、それ以外の変更は最大で TTL かかります（期限切れ直後の1人目には、裏で更新している間だけ古いページが返ることがあります）。
- 作り直しは、秘密の値を付けた `X-Turbo-Refresh` ヘッダーで nginx に依頼します。値を知らない人がこのヘッダーを付けても、普通の訪問者として扱われます。複数サイト構成では秘密の値はサイトごとに別で、あるサイトの値で他のサイトは作り直せません。
- キャッシュのキーにはスキーム・メソッド・ホスト名・URL 全体を含むので、サイト同士で混ざりません。キーとアプリへ渡す URL は常に同じものです（キーにだけ含まれない値でキャッシュを汚されないように）。
- 公開してはいけない内容を消したときは、`sh purge-site.sh <サイト名>` でそのサイトのキャッシュを今すぐ全部消せます（サイトを削除したときは自動で消えます）。
- Cookie を使わずに訪問者ごとに内容を変えるページ（IP アドレスや `User-Agent` で出し分けるなど）は、`Cache-Control: private` を返してください。
- アップロードフォルダの PHP は実行されません。ドットファイル（`.env`、`.git` など）は配信しません。

## テスト済みの環境

変更のたびに、`tests/` の5種類のテストで確認しています。

- `tests/python-multisite/`：Django の複数サイト構成で、サイト間の分離（設定・データ・コード・ソケット・プロセス）、root で動かないこと、キャッシュ、アクセスのないサイトの停止と再起動、同時起動数の上限と入れ替え、更新時の作り直し（他サイトの秘密の値では不可、gzip を要求するブラウザにもすぐ反映）、圧縮済みキャッシュ、追跡パラメータの除去とすり抜けの試み（`;` 区切り・符号化した名前・他のパラメータとの混在）、訪問者が圧縮の指示ヘッダーを偽れないこと、サイト単位のキャッシュ削除、Flask サイトの追加、起動に失敗するサイトの扱い、再起動なしの追加・削除、正常終了を確認、処理中のサイトを止めないこと（アイドル停止・入れ替えの両方）、知らない Cookie でキャッシュしないこと、偽の転送スキームでキャッシュを汚されないこと（79項目）
- `tests/multisite/`：複数サイト構成で、サイトごとのユーザーで動くこと、他のサイトのユーザーではファイル・`wp-config.php`・PHP の接続口・ヘルスチェック用の接続口に触れないこと（`open_basedir` なしでも）、一時ファイルがサイト専用であること、PHP がアップロードしたファイルを nginx が配信できること、サイト間でファイルが読めないこと、共有の本体を書き換えられないこと、本体のコンパイルが全サイトで1回であること、キャッシュが混ざらないこと、更新時の作り直し、アクセスのないサイトの PHP プロセスが0になること、再起動なしの追加・削除を確認（44項目）
- `tests/wp/`：Docker 構成に wp-cli で本物の WordPress を入れ、キャッシュの HIT/MISS/BYPASS、圧縮済みキャッシュ、追跡パラメータ、ログイン、コメント、更新時の作り直し（gzip を要求するブラウザにもすぐ反映）、プラグイン導入、OPcache の再読み込み、アップロードと PHP 実行の制限、再起動を確認（66項目）
- `tests/native/`：各ディストリビューション標準のパッケージに `native/install.sh` を入れ、dry-run、壊れた nginx 設定での自動ロールバック、アンインストールまで確認
- `tests/python/`：本物の gunicorn で、ウォームアップ、ワーカーごとの DB 接続（PostgreSQL）、480件の同時リクエスト、SIGHUP での再読み込み、CPU 制限の検出、通常の gunicorn とのメモリ比較を確認

下の表の全環境での実行は 2026-10-25（当時の項目数）。2026-10-27〜28 の変更（圧縮済みキャッシュ・追跡パラメータ・自動調整・処理中のサイトを止めない・Cookie の扱い・WordPress のサイト別ユーザーなど）のあとは、
次の組み合わせで全項目の通過を確認しています（2026-10-28）：`tests/python-multisite`（Python 3.12・Django 5.2・gunicorn 23、79項目）、
`tests/wp`（php8.3-fpm-alpine・nginx 1.26-alpine・MariaDB 11.4、66項目）、`tests/multisite`（44項目）、`tests/native`（Debian 12、31項目）。

**Docker 構成（`tests/wp`、各62項目）**

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

**Django 複数サイト構成（`tests/python-multisite`、各51項目）**

| Python | Django | gunicorn |
|---|---|---|
| 3.8 | 4.2 | 20.1 |
| 3.10 | 4.2 | 21.2 |
| 3.11 | 5.2 | 22.0 |
| 3.12 | 5.2 | 23.0 |
| 3.12 Alpine（musl） | 6.1 | 26.2 |
| 3.13 | 6.1 | 26.2 |
| 3.14 | 6.1 | 26.2 |
| 3.12（**arm64**、QEMU） | 6.1 | 26.2 |

**既存サーバー（`tests/native`、各31項目）**：標準パッケージのみ使用

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

## 収容数ベンチマーク

### WordPress

`bench/density.sh` は、同じ2コアにすべてのコンテナを固定し、サイトを段階的に増やしながら次を測ります。

- **従来の構成**：1サイトにつき公式 `wordpress:php8.3-apache` コンテナを1つ。データベースは全サイトで1つ共有（従来側に有利な条件）
- **nexcore-turbo**：`docker/multisite`
- **負荷**：全サイトに均等にアクセスし、その1割はキャッシュの効かない検索（`/?s=...`）。各サイトの全ページを1回表示し、同じ負荷で60秒の準備運転をしてから60秒計測
- **合格**：エラー0件、応答時間の95%値が0.5秒以内、全コンテナ（Web・PHP・DB）のメモリ合計が2GB以内

2026-10-25 実施。多コアの x86_64 サーバーで2コアに固定し、負荷をかける側は別のコアで動かしました。

**重い負荷（1サイトあたり毎秒0.5件＝1日 約4万PV）**

| | サイト数 | 応答時間 95%値 | 検索の95%値 | エラー | メモリ合計 | CPU | 判定 |
|---|---|---|---|---|---|---|---|
| 従来 | 12 | 160ms | 150ms | 0 | 1,721MB | 88% | 合格 |
| 従来 | 14 | 160ms | 147ms | 0 | 1,982MB | 89% | 合格 |
| 従来 | 15 | 157ms | 147ms | 0 | 2,108MB | 93% | 不合格（メモリ） |
| nexcore-turbo | 75 | 134ms | 200ms | 0 | 438MB | 19% | 合格 |
| nexcore-turbo | 100 | 133ms | 210ms | 0 | 507MB | 46% | 合格 |
| nexcore-turbo | 150 | 140ms | 314ms | 0 | 735MB | 113% | 合格 |
| nexcore-turbo | 200 | 165ms | 424ms | 3（約6,000件中） | 893MB | 154% | 不合格（エラー） |

（CPU は2コアで200%が上限。従来の構成はキャッシュを持たないため、全ページの事前表示は省き準備運転のみ。生データ：[従来](docs/density-2026-10-25-baseline.txt)、[nexcore-turbo](docs/density-2026-10-25-turbo-heavy.txt)）

**標準的な負荷（1サイトあたり毎秒0.05件＝1日 約4,300PV）**

| | サイト数 | 応答時間 95%値 | 検索の95%値 | エラー | メモリ合計 | CPU | 判定 |
|---|---|---|---|---|---|---|---|
| 従来 | 14 | — | — | — | 約1,900MB（待機時） | — | 上限（メモリ） |
| nexcore-turbo | 200 | 151ms | 191ms | 0 | 734MB | 14% | 合格 |
| nexcore-turbo | 400 | 190ms | 221ms | 0 | 1,058MB | 135% | 合格 |
| nexcore-turbo | 600 | タイムアウト | タイムアウト | 951 | 2,185MB | 200% | 不合格 |

（従来の構成は重い負荷でも CPU に余裕がありメモリで止まったため、待機時のメモリから14サイトで頭打ちと判断。生データ：[nexcore-turbo](docs/density-2026-10-25-turbo-typical.txt)）

従来の構成はアクセスがなくても1サイト約130MBを使うため、負荷に関係なくメモリで上限が決まります。
nexcore-turbo はメモリに余裕があり、CPU（キャッシュの効かない検索などの処理）が上限を決めます。600サイトでは CPU が100%張り付き、待ちの PHP プロセスが溜まってメモリも超えました。

### Django

`bench/density-django.sh` で、同じ条件（2コア・2GB・同じアクセスの混ぜ方・同じ合格条件）で測りました。
サイトはどちらもデモのブログ（記事10件、SQLite）で、DB のコンテナはありません。

- **従来の構成**：1サイトにつきコンテナ1つで `gunicorn -w 2`（ワーカー2つ）
- **nexcore-turbo**：`docker/python-multisite`（当時の初期設定のまま。`TURBO_IDLE=10`、`TURBO_MAX_ACTIVE=60`）

**重い負荷（1サイトあたり毎秒0.5件）**

| | サイト数 | 応答時間 95%値 | 検索の95%値 | エラー | メモリ合計 | CPU | 動いていたサイト数 | 判定 |
|---|---|---|---|---|---|---|---|---|
| 従来 | 24 | 6ms | 6ms | 0 | 1,799MB | 5% | 24 | 合格 |
| 従来 | 26 | 6ms | 6ms | 0 | 1,950MB | 8% | 26 | 合格 |
| 従来 | 28 | 9ms | 6ms | 0 | 2,103MB | 8% | 28 | 不合格（メモリ） |
| nexcore-turbo | 100 | 55ms | 82ms | 0 | 1,161MB | 19% | 42 | 合格 |
| nexcore-turbo | 200 | 160ms | 177ms | 0 | 1,505MB | 50% | 60 | 合格 |
| nexcore-turbo | 400 | 162ms | 220ms | 0 | 1,566MB | 131% | 60 | 合格 |
| nexcore-turbo | 500 | 163ms | 277ms | 0 | 1,641MB | 109% | 60 | 合格 |
| nexcore-turbo | 600 | 201ms | 513ms | 0 | 1,687MB | 194% | 59 | 合格 |
| nexcore-turbo | 700 | 741ms | 5,512ms | 57 | 1,425MB | 201% | 58 | 不合格（CPU） |

（400サイトまでと500サイトからは、別々に新しく作った環境での計測です）

**標準的な負荷（1サイトあたり毎秒0.05件）**

| | サイト数 | 応答時間 95%値 | 検索の95%値 | エラー | メモリ合計 | CPU | 動いていたサイト数 | 判定 |
|---|---|---|---|---|---|---|---|---|
| 従来 | 26 | – | – | – | 約1,940MB（待機時） | – | 26 | 上限（メモリ） |
| nexcore-turbo | 200 | 73ms | 87ms | 0 | 322MB | 8% | 8 | 合格 |
| nexcore-turbo | 400 | 75ms | 85ms | 0 | 762MB | 21% | 21 | 合格 |
| nexcore-turbo | 600 | 74ms | 89ms | 0 | 1,122MB | 35% | 26 | 合格 |
| nexcore-turbo | 800 | 63ms | 82ms | 0 | 1,355MB | 32% | 47 | 合格 |
| nexcore-turbo | 1,000 | 160ms | 187ms | 0 | 1,700MB | 59% | 58 | 合格 |

（生データ：[従来](docs/density-2026-10-25-django-baseline.txt)、[重い負荷](docs/density-2026-10-25-django-heavy.txt)、[標準的な負荷](docs/density-2026-10-25-django-typical.txt)）

従来の構成は CPU に余裕があってもメモリで止まります。nexcore-turbo は、同時に動くサイト数の上限（60）で
メモリを2GB以内に抑え、上限に達したら使われていないサイトから入れ替えるため、メモリは1.7GB前後で頭打ちになり、
最後は CPU（重い負荷では700サイトで200%）が上限を決めます。

**古い PC でも同じ結果になるか（別のマシンでの再計測）**

上の数字は大きなサーバーから2コアを切り出して測ったものです。普通の古い PC でも同じになるか、
2013年発売の4コア CPU を積んだ古い PC（16GB）で、同じ2コア・2GB・重い負荷の条件で測り直しました
（準備運転は30秒に短縮。マシン上の他のサービスは止めて計測）。

| | サイト数 | 応答時間 95%値 | 検索の95%値 | エラー | メモリ合計 | CPU | 判定 |
|---|---|---|---|---|---|---|---|
| 従来 | 26 | 8ms | 5ms | 0 | 1,944MB | – | 合格 |
| 従来 | 30 | 7ms | 6ms | 0 | 2,245MB | – | 不合格（メモリ） |
| nexcore-turbo | 200 | 158ms | 182ms | 0 | 1,514MB | 22% | 合格 |
| nexcore-turbo | 400 | 162ms | 254ms | 0 | 1,609MB | 100% | 合格 |
| nexcore-turbo | 600 | 231ms | 576ms | 0 | 1,623MB | 170% | 合格 |

従来26サイトに対して600サイトで、約23倍という結果は古い PC でも変わりませんでした。600サイトで CPU は170%に達し、
検索の95%値は500msを超えているので、このマシンではここがほぼ上限です（600サイトより上は測っていません）。
従来の CPU は計測のタイミングがずれていたため載せていません（[生データ](docs/density-2026-10-25-django-oldpc.txt)）。

### より重い Django アプリでの計測

デモより重い Django のブログアプリ（アプリ5つ、Markdown・Pillow・Pygments 使用、ページ16種類）を
2026-10-27 に同じ2コア・2GB で測りました。デモより1サイトが重く、動いている間は1サイト約31〜49MB を使います。

| | 標準的な負荷 | 重い負荷 |
|---|---|---|
| 従来（1サイト1コンテナ、`gunicorn -w 2`） | 15サイト（20でメモリ超過） | 15サイト |
| nexcore-turbo（同時に動かすサイトを32に固定） | **400サイト**（95%値 495ms。600でメモリ超過） | 100サイトで不合格（95%値 994ms） |

重い負荷では全サイトに常にアクセスがあるため、同時に動かせる数（このときは手で32に固定）を超えたサイトの止める・起こすが続き、
応答が遅くなりました。この計測のあと、同時に動かす数を使用量から自動で決める仕組み（このブログでは約44〜48）と、
圧縮済みキャッシュを入れています。600サイトでの「メモリ超過」には、ファイル情報などカーネルが必要に応じて手放すキャッシュも
含まれていたため、`bench/density-django.sh` は手放せないメモリ（`hard-mem`）で判定するように変えました。どちらも現行版での測り直しはまだです。

同じブログで、50人が同時にキャッシュ済みのページを見る場合（ブラウザと同じく gzip を要求）：

| | 1秒あたりの処理件数 | 応答時間（95%値） |
|---|---|---|
| 従来（`gunicorn -w 2`） | 134 | 445ms |
| nexcore-turbo（圧縮済みキャッシュの前） | 4,309 | 13.9ms |
| nexcore-turbo（現行版） | **29,365** | **2.6ms** |

フォームのあるページ（CSRF の Cookie を発行するため保存できない）を混ぜると、そのページの処理が上限を決めます
（このブログで16ページ中1ページ混ぜた場合、毎秒約1,265件）。

## 運用で知っておくこと

- **更新と再起動**：サイトサーバー（`app`）や nginx の更新・再起動の間は、全サイトが数秒止まります。
- **バックアップ**：入っていません。Docker のボリューム（`sites`、WordPress は DB も）を別途バックアップしてください。
- **監視**：応答ヘッダー `X-Turbo-Cache`（`HIT`/`MISS`/`BYPASS`）でキャッシュの効き方が分かります。サイトサーバーのログは
  `docker compose logs app` です。サイトごとのログが欲しいときは、そのサイトの `turbo.env` に `TURBO_LOG_FILE=<パス>` を書きます
  （起動時のエラーも含み、`TURBO_LOG_MAX`＝5MB で切り替え）。
- **キャッシュに残る時間**：初期値は24時間です。記事の更新ではすぐ作り直されますが、それ以外で公開をやめた内容は
  `purge-site.sh` で消してください。

## 1サイトの速度ベンチマーク

`bench/run.sh` は、公式の `wordpress:php8.3-apache` イメージと nexcore-turbo を同じ
2コア・2GB に閉じ込め、標準テーマで同じ記事を作り、k6 で50人の同時アクセスをかけます。
k6 はブラウザと同じく `Accept-Encoding: gzip` を送ります。

2026-10-27 実施（30秒×3回）。多コアの x86_64 サーバーで2コアに固定し、負荷をかける側は別のコアで
動かしました（[生の出力](docs/bench-2026-10-27-gzip.txt)）。

| | 公式イメージ | nexcore-turbo |
|---|---|---|
| 1秒あたりの処理件数（3回） | 33.1〜34.2 | 23,441〜23,648 |
| 応答時間（95%値） | 1.59〜1.64秒 | 5.1〜5.3ミリ秒 |
| メモリ（WordPress / nginx / DB） | 559MB / – / 113MB | 74MB / 12MB / 92MB |
| エラー | 0 | 0 |

最も不利な組み合わせ（nexcore-turbo の最低値 ÷ 公式イメージの最高値）：**23,441 ÷ 34.20 = 約685倍**

以前この README に載せていた「828倍」（2026-10-24、[生の出力](docs/bench-2026-10-24.txt)）は、k6 が gzip を
要求しない条件での数字でした。ブラウザは必ず gzip を要求するので、こちらの数字に置き換えています。
（当時の版は、キャッシュから返すたびに nginx が圧縮し直していたため、ブラウザからの実際の速度はもっと低いものでした。）

この数字は、ログインしていない訪問者がキャッシュ済みのページを見る場合のものです。
ログイン中の操作、フォーム送信、カートには当てはまりません。実際の速度はサイトの内容や
通信環境によって変わります。

## ライセンス

MIT
