FROM dunglas/frankenphp:1.12.1-php8.4 AS runner
ARG USER
ARG SHARED_GID=2000
ARG SHARED_GROUP=abcnorio
ENV APP_USER=${USER}
ENV SHARED_GID=${SHARED_GID}
ENV SHARED_GROUP=${SHARED_GROUP}

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

RUN existing_group="$(getent group ${SHARED_GID} | cut -d: -f1 || true)" \
    && if [ -n "${existing_group}" ] && [ "${existing_group}" != "${SHARED_GROUP}" ]; then \
        groupmod -n ${SHARED_GROUP} "${existing_group}"; \
    elif ! getent group ${SHARED_GROUP} >/dev/null; then \
        groupadd -g ${SHARED_GID} ${SHARED_GROUP}; \
    fi
RUN usermod -a -G ${SHARED_GID} ${USER}

RUN chown -R ${USER}:${USER} /config/caddy /data/caddy
RUN curl -o /bin/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && \
    chmod +x /bin/wp-cli.phar && \
    ln -s /bin/wp-cli.phar /bin/wp

CMD ["sh", "-lc", "umask 0002 && mkdir -p /app/web/app/cache/acorn/framework/views /app/web/app/cache/acorn /astro/build-archives /shared/static/dev /shared/static/staging /shared/static/prod && chown -R ${APP_USER}:${APP_USER} /app/web/app/cache/acorn && chmod -R ug+rwX /app/web/app/cache/acorn && chgrp -R ${SHARED_GID} /astro/build-archives /shared/static && find /astro/build-archives /shared/static -type d -exec chmod 2775 {} + && find /astro/build-archives /shared/static -type f -exec chmod 664 {} + && exec su -s /bin/sh -c 'umask 0002 && frankenphp run --config /etc/caddy/Caddyfile --resume=false' ${APP_USER}"]
