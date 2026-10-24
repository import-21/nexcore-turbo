<?php
/*
 * Test-only endpoints for the nexcore-turbo suite. Never install on a real site.
 *   /?turbo_test=...  is avoided on purpose (query strings bypass the cache);
 *   the routes below are path-based so they are cache candidates.
 */
add_action('init', function () {
    $path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);
    $now  = sprintf('%.6f', microtime(true));
    switch ($path) {
        case '/turbo-test/stamp':
            header('Content-Type: text/plain');
            echo "stamp=$now";
            exit;
        case '/turbo-test/sets-cookie':
            setcookie('turbo_test', '1', 0, '/');
            header('Content-Type: text/plain');
            echo "cookie=$now";
            exit;
        case '/turbo-test/private':
            header('Cache-Control: private, max-age=0');
            header('Content-Type: text/plain');
            echo "private=$now";
            exit;
        case '/turbo-test/no-store':
            header('Cache-Control: no-store');
            header('Content-Type: text/plain');
            echo "nostore=$now";
            exit;
        case '/turbo-test/host':
            header('Content-Type: text/plain');
            echo 'host=' . ($_SERVER['HTTP_HOST'] ?? '') . " $now";
            exit;
        case '/turbo-test/error':
            http_response_code(500);
            echo "error=$now";
            exit;
        case '/turbo-test/opcache':
            header('Content-Type: text/plain');
            echo 'opcache=' . (function_exists('opcache_get_status') && opcache_get_status(false)['opcache_enabled'] ? 'on' : 'off');
            echo ' validate=' . ini_get('opcache.validate_timestamps');
            $st = function_exists('opcache_get_status') ? opcache_get_status(false) : [];
            echo ' jit=' . (!empty($st['jit']['enabled']) && !empty($st['jit']['on']) ? 'active' : 'off');
            echo ' php=' . PHP_VERSION;
            exit;
        case '/turbo-test/edit-me':
            header('Content-Type: text/plain');
            echo 'version=' . (include __DIR__ . '/turbo-edit-me.inc.php');
            exit;
    }
});
