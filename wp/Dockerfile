FROM dunglas/frankenphp:1.12.1-php8.4 AS runner
ARG USER
ARG SHARED_GID=2000
ARG SHARED_GROUP=abcnorio
ENV APP_USER=${USER}
ENV SHARED_GID=${SHARED_GID}
ENV SHARED_GROUP=${SHARED_GROUP}

RUN install-php-extensions \
    apcu \
    bcmath \
    mysqli \
    gd \
    imagick \
    exif \
    curl \
    intl \
    zip

COPY --from=composer:2.9.5 /usr/bin/composer /usr/bin/composer

COPY --from=node:22-slim /usr/local/bin/node /usr/local/bin/node
COPY --from=node:22-slim /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

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

CMD ["sh", "-lc", "exec su -s /bin/sh -c 'umask 0002 && frankenphp run --config /etc/caddy/Caddyfile --resume=false' ${APP_USER}"]
