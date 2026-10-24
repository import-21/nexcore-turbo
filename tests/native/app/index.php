<?php
// Front controller used by the native-install tests (stands in for WordPress).
$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);
$now  = sprintf('%.6f', microtime(true));
header('Content-Type: text/plain');
switch ($path) {
    case '/info':
        $st = function_exists('opcache_get_status') ? opcache_get_status(false) : false;
        echo 'opcache=' . ($st && $st['opcache_enabled'] ? 'on' : 'off');
        echo ' validate=' . ini_get('opcache.validate_timestamps');
        echo ' freq=' . ini_get('opcache.revalidate_freq');
        echo ' jit=' . (ini_get('opcache.jit') ?: 'none');
        echo ' php=' . PHP_VERSION;
        break;
    case '/sets-cookie':
        setcookie('t', '1', 0, '/');
        echo "cookie=$now";
        break;
    case '/private':
        header('Cache-Control: private');
        echo "private=$now";
        break;
    case '/host':
        echo 'host=' . ($_SERVER['HTTP_HOST'] ?? '') . " $now";
        break;
    case '/edit-me':
        echo 'version=' . (include __DIR__ . '/edit-me.inc.php');
        break;
    default:
        echo "page=$path $now";
}
