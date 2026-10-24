<?php
/**
 * Plugin Name: nexcore-turbo cache refresh
 * Description: Re-renders the cached copies of a post, the home page and the post's categories right after content changes, so the page cache can keep pages for a long time.
 * Version: 0.1.0
 * License: MIT
 *
 * Install as a must-use plugin (wp-content/mu-plugins/). Configure with
 * constants in wp-config.php or environment variables:
 *   TURBO_REFRESH_SECRET  the same secret as in nginx's turbo/refresh/*.map
 *   TURBO_REFRESH_URL     where nginx listens from this server (default http://127.0.0.1)
 */

if (!defined('ABSPATH')) {
    exit;
}

final class Nexcore_Turbo_Refresh
{
    private static $urls = [];

    private static function setting($name, $default = '')
    {
        if (defined($name)) {
            return (string) constant($name);
        }
        $env = getenv($name);
        return is_string($env) && $env !== '' ? $env : $default;
    }

    private static function add($url)
    {
        if (is_string($url) && $url !== '') {
            self::$urls[$url] = true;
        }
    }

    public static function post($post_id)
    {
        $post = get_post($post_id);
        if (!$post || wp_is_post_revision($post) || wp_is_post_autosave($post) || !is_post_type_viewable($post->post_type)) {
            return;
        }
        self::add(get_permalink($post));
        self::add(home_url('/'));
        $posts_page = (int) get_option('page_for_posts');
        if ($posts_page) {
            self::add(get_permalink($posts_page));
        }
        if ($post->post_type === 'post') {
            foreach (wp_get_post_categories($post->ID) as $cat) {
                self::add(get_category_link($cat));
            }
        }
    }

    public static function home()
    {
        self::add(home_url('/'));
    }

    public static function status_change($new, $old, $post)
    {
        if ($new === 'publish' || $old === 'publish') {
            self::post($post);
        }
    }

    public static function comment($comment_id)
    {
        $comment = get_comment($comment_id);
        if ($comment && $comment->comment_approved === '1') {
            self::post($comment->comment_post_ID);
        }
    }

    public static function flush()
    {
        $secret = self::setting('TURBO_REFRESH_SECRET');
        if (!self::$urls || $secret === '') {
            return;
        }
        // Let the visitor's browser go first; the refresh happens afterwards.
        if (function_exists('fastcgi_finish_request')) {
            fastcgi_finish_request();
        }
        $target = rtrim(self::setting('TURBO_REFRESH_URL', 'http://127.0.0.1'), '/');
        foreach (array_keys(self::$urls) as $url) {
            $p = wp_parse_url($url);
            if (empty($p['host']) || !empty($p['query'])) {
                continue;   // pages with a query string are never cached
            }
            wp_remote_get($target . ($p['path'] ?? '/'), [
                'timeout'     => 10,
                'redirection' => 0,
                'sslverify'   => false,
                'headers'     => [
                    'Host'            => $p['host'] . (isset($p['port']) ? ':' . $p['port'] : ''),
                    'X-Turbo-Refresh' => $secret,
                ],
            ]);
        }
        self::$urls = [];
    }
}

add_action('transition_post_status', ['Nexcore_Turbo_Refresh', 'status_change'], 10, 3);
add_action('deleted_post', ['Nexcore_Turbo_Refresh', 'post']);
add_action('wp_insert_comment', ['Nexcore_Turbo_Refresh', 'comment']);
add_action('wp_set_comment_status', ['Nexcore_Turbo_Refresh', 'comment']);
add_action('edit_comment', ['Nexcore_Turbo_Refresh', 'comment']);
add_action('wp_update_nav_menu', ['Nexcore_Turbo_Refresh', 'home']);
add_action('customize_save_after', ['Nexcore_Turbo_Refresh', 'home']);
add_action('switch_theme', ['Nexcore_Turbo_Refresh', 'home']);
add_action('update_option_blogname', ['Nexcore_Turbo_Refresh', 'home']);
add_action('update_option_blogdescription', ['Nexcore_Turbo_Refresh', 'home']);
add_action('shutdown', ['Nexcore_Turbo_Refresh', 'flush'], 100);
