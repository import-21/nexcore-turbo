# PHP-FPM runtime for many WordPress sites: the official image, wp-cli, and one
# shared, read-only WordPress core (kept in /opt/turbo-core, published to the
# shared /srv/core volume on every start so nginx sees the same files). Every site links to that core,
# so OPcache compiles WordPress once instead of once per site.
ARG WORDPRESS_TAG=php8.3-fpm-alpine
FROM wordpress:cli AS cli
FROM wordpress:${WORDPRESS_TAG}
COPY --from=cli /usr/local/bin/wp /usr/local/bin/wp
COPY docker/multisite/core-wp-config.php /tmp/core-wp-config.php
COPY wordpress/nexcore-turbo-refresh.php /tmp/nexcore-turbo-refresh.php
RUN rm -f /usr/local/etc/php-fpm.d/*.conf /usr/local/etc/php-fpm.d/*.default \
 && cp -a /usr/src/wordpress /opt/turbo-core \
 && rm -f /opt/turbo-core/wp-config-docker.php \
 && mv /tmp/core-wp-config.php /opt/turbo-core/wp-config.php \
 && mkdir /opt/turbo-core/turbo-mu-plugins && mv /tmp/nexcore-turbo-refresh.php /opt/turbo-core/turbo-mu-plugins/ \
 && chown -R root:root /opt/turbo-core && chmod -R a+rX,go-w /opt/turbo-core \
 && mkdir -p /run/php /srv/sites && chown www-data:www-data /run/php /srv/sites
ENTRYPOINT []
CMD ["php-fpm", "-F"]
