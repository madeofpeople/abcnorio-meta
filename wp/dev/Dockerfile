FROM dunglas/frankenphp:1.12.1-php8.4 AS runner
ARG USER
ENV APP_USER=${USER}

RUN install-php-extensions \
    bcmath \
    mysqli \
    gd \
    imagick \
    exif \
    curl \
    intl \
    zip

COPY --from=composer:2.9.5 /usr/bin/composer /usr/bin/composer

RUN chown -R ${USER}:${USER} /config/caddy /data/caddy
RUN curl -o /bin/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && \
    chmod +x /bin/wp-cli.phar && \
    ln -s /bin/wp-cli.phar /bin/wp

CMD ["sh", "-lc", "mkdir -p /app/web/app/cache/acorn/framework/views /app/web/app/cache/acorn/framework/cache && chown -R ${APP_USER}:${APP_USER} /app/web/app/cache/acorn && chmod -R ug+rwX /app/web/app/cache/acorn && if [ -d /astro/prod ]; then chown -R ${APP_USER}:${APP_USER} /astro/prod && chmod -R ug+rwX /astro/prod; fi && exec su -s /bin/sh -c 'frankenphp run --config /etc/caddy/Caddyfile --resume=false' ${APP_USER}"]
