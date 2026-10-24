<?php
/*
 * Shared core: WordPress looks for wp-config.php next to its own files, which
 * are shared by every site. Load the real config of the site this PHP-FPM pool
 * belongs to. TURBO_SITE comes from the pool definition (env[TURBO_SITE]),
 * never from the request.
 */
$turbo_site = getenv('TURBO_SITE');
if (!is_string($turbo_site) || !preg_match('/^[a-z0-9][a-z0-9-]{0,40}$/', $turbo_site)
    || !is_file('/srv/sites/' . $turbo_site . '/wp-config.php')) {
    http_response_code(500);
    exit('site not configured');
}
require '/srv/sites/' . $turbo_site . '/wp-config.php';
