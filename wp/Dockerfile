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

RUN apt-get update && apt-get install -y --no-install-recommends ghostscript && rm -rf /var/lib/apt/lists/*

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

RUN cat > /usr/local/bin/wp-permissions-preflight <<'EOF' \
        && chmod +x /usr/local/bin/wp-permissions-preflight
#!/usr/bin/env sh
set -eu

uploads_dir="/app/web/app/uploads"
expected_uid="${PROJECT_UID:-1000}"
expected_gid="${PROJECT_GID:-${SHARED_GID}}"

if [ ! -d "$uploads_dir" ]; then
    echo "[startup] FATAL: uploads dir missing: $uploads_dir" >&2
    exit 1
fi

actual_uid="$(stat -c '%u' "$uploads_dir")"
actual_gid="$(stat -c '%g' "$uploads_dir")"

if [ "$actual_uid" != "$expected_uid" ]; then
    if [ "$actual_uid" != "0" ]; then
        echo "[startup] FATAL: uploads owner UID is $actual_uid (expected $expected_uid): $uploads_dir" >&2
        echo "[startup] Run one-time migration: bash install.sh migrate-permissions-once" >&2
        exit 1
    fi
fi

if [ "$actual_gid" != "$expected_gid" ]; then
    if [ "$actual_uid" != "0" ]; then
        echo "[startup] FATAL: uploads group GID is $actual_gid (expected $expected_gid): $uploads_dir" >&2
        echo "[startup] Run one-time migration: bash install.sh migrate-permissions-once" >&2
        exit 1
    fi
fi

if [ ! -g "$uploads_dir" ]; then
    echo "[startup] FATAL: uploads dir missing setgid bit: $uploads_dir" >&2
    echo "[startup] Expected dirs mode 2775 under uploads." >&2
    exit 1
fi

if ! su -s /bin/sh -c "test -w '$uploads_dir'" "${APP_USER}"; then
    echo "[startup] FATAL: APP_USER ${APP_USER} cannot write uploads dir: $uploads_dir" >&2
    exit 1
fi

if ! id -G "${APP_USER}" | tr ' ' '\n' | grep -qx "$expected_gid"; then
    echo "[startup] FATAL: APP_USER ${APP_USER} is not in required GID $expected_gid" >&2
    exit 1
fi

probe_file="$uploads_dir/.wp-write-probe-$$"
if ! su -s /bin/sh -c "umask 0002 && : > '$probe_file'" "${APP_USER}"; then
    echo "[startup] FATAL: APP_USER ${APP_USER} write probe failed in $uploads_dir" >&2
    exit 1
fi
rm -f "$probe_file"
EOF

CMD ["sh", "-lc", "/usr/local/bin/wp-permissions-preflight && exec su -s /bin/sh -c 'umask 0002 && frankenphp run --config /etc/caddy/Caddyfile --resume=false' ${APP_USER}"]
