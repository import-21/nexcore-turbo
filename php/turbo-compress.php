<?php
// nexcore-turbo: gzip a cacheable page once, in PHP, so nginx caches it compressed and sends a
// cache hit as stored instead of gzipping it again for every visitor (nginx gunzips for the rare
// client without gzip). nginx sets X-Turbo-Compress (always 0 or 1, never the client's) to 1 only
// for anonymous cookie-less GET/HEAD it may cache. Never a response that sets a cookie or is
// private (it may hold a secret: BREACH), and no "Vary: Accept-Encoding" from here: the cache
// holds one copy whatever the visitor asked for, so a refresh replaces the page for everyone.
if (($_SERVER['HTTP_X_TURBO_COMPRESS'] ?? '') === '1' && ($_SERVER['REQUEST_METHOD'] ?? '') === 'GET'
        && function_exists('gzencode') && !ini_get('zlib.output_compression')) {
    ob_start(static function ($buffer, $phase) {
        static $off = false;
        $whole = ($phase & PHP_OUTPUT_HANDLER_START) && ($phase & PHP_OUTPUT_HANDLER_FINAL);
        if ($off || !$whole || headers_sent() || strlen($buffer) < 1024 || http_response_code() !== 200) {
            $off = true;                                   // flushed early or not a full page: as it is
            return false;
        }
        $type = '';
        foreach (headers_list() as $h) {
            [$name, $value] = array_map('trim', explode(':', $h, 2) + [1 => '']);
            $name = strtolower($name);
            if ($name === 'set-cookie' || $name === 'content-encoding'
                    || ($name === 'cache-control' && preg_match('/private|no-store/i', $value))) {
                return false;
            }
            if ($name === 'content-type') {
                $type = strtolower($value);
            }
        }
        if ($type !== '' && !preg_match('#^(text/|application/(json|javascript|xml|rss\+xml|atom\+xml|ld\+json)|image/svg\+xml)#', $type)) {
            return false;
        }
        header('Content-Encoding: gzip');
        header_remove('Content-Length');
        return gzencode($buffer, 6);
    }, 0);
}
