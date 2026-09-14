# SPDX-License-Identifier: AGPL-3.0-only
#
# Custom image built from a git checkout of this fork's source
# (feature/sync-disabled-external-storage branch) instead of an official
# release tarball, so the new enable_sync/sync-enabled property can
# actually be tested end-to-end.
#
# Build (from the repo root, on this branch):
#   docker build -t nextcloud-sync-test:local .
#
# Run (example, SQLite for a quick test instance):
#   docker run -d --name nextcloud-sync-test \
#     -p 8443:80 \
#     -v nextcloud-sync-test-data:/var/www/html \
#     nextcloud-sync-test:local

ARG PHP_VERSION=8.3

# ---- Stage 1: PHP dependencies ----
# Full source (not just composer.json/lock) — composer's autoloader
# generation scans real source paths declared in composer.json, and a
# minimal-context copy was observed to silently produce no vendor/ dir.
FROM composer:2 AS composer
WORKDIR /app
COPY . .
RUN composer install --no-dev --prefer-dist --no-scripts --no-interaction --ignore-platform-reqs

# ---- Stage 2: frontend build (Vue/TS bundles, incl. the new checkbox) ----
FROM node:24 AS frontend
# Some npm deps compile native addons (node-gyp) — cheap insurance,
# harmless if unneeded.
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY . .
RUN npm ci && npm run build

# ---- Stage 3: runtime ----
FROM php:${PHP_VERSION}-apache

RUN set -ex; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        busybox-static \
        bzip2 \
        libcurl4-openssl-dev \
        libevent-dev \
        libfreetype6-dev \
        libgmp-dev \
        libicu-dev \
        libjpeg-dev \
        libldap-common \
        libldap2-dev \
        liblz4-dev \
        libmagickwand-dev \
        libmemcached-dev \
        libpng-dev \
        libpq-dev \
        libwebp-dev \
        libxml2-dev \
        libzip-dev \
        rsync \
    ; \
    debMultiarch="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-configure ldap --with-libdir="lib/$debMultiarch"; \
    docker-php-ext-install -j "$(nproc)" \
        bcmath \
        exif \
        ftp \
        gd \
        gmp \
        intl \
        ldap \
        pcntl \
        pdo_mysql \
        pdo_pgsql \
        sysvsem \
        zip \
    ; \
    pecl install APCu igbinary imagick memcached redis; \
    docker-php-ext-enable apcu igbinary imagick memcached redis; \
    mkdir -p /var/spool/cron/crontabs; \
    echo '*/5 * * * * php -f /var/www/html/cron.php' > /var/spool/cron/crontabs/www-data

ENV PHP_MEMORY_LIMIT=512M
ENV PHP_UPLOAD_LIMIT=512M
RUN { \
        echo 'memory_limit=${PHP_MEMORY_LIMIT}'; \
        echo 'upload_max_filesize=${PHP_UPLOAD_LIMIT}'; \
        echo 'post_max_size=${PHP_UPLOAD_LIMIT}'; \
    } > "$PHP_INI_DIR/conf.d/nextcloud.ini"; \
    mkdir -p /docker-entrypoint-hooks.d/pre-installation \
             /docker-entrypoint-hooks.d/post-installation \
             /docker-entrypoint-hooks.d/pre-upgrade \
             /docker-entrypoint-hooks.d/post-upgrade \
             /docker-entrypoint-hooks.d/before-starting

# Layer both build stages' full trees on top of each other rather than
# cherry-picking specific subfolders (e.g. vendor/) cross-stage — that
# was fragile in practice (composer's root vendor/ is legitimately near
# -empty for this project; the real runtime deps live in the 3rdparty
# git submodule, already present in source since checkout fetches it).
# Composer's tree goes first, then frontend's built JS/CSS overlays on
# top without disturbing anything composer-specific it doesn't touch.
COPY --from=composer /app /usr/src/nextcloud
COPY --from=frontend /app /usr/src/nextcloud

RUN mkdir -p /usr/src/nextcloud/data /usr/src/nextcloud/custom_apps; \
    rm -rf /usr/src/nextcloud/updater; \
    chmod +x /usr/src/nextcloud/occ; \
    chown -R www-data:root /usr/src/nextcloud; \
    chown -R www-data:root /var/www; \
    chmod -R g=u /var/www

COPY docker-entrypoint.sh /entrypoint.sh
COPY docker-cron.sh /cron.sh
COPY upgrade.exclude /
COPY config/*.php /usr/src/nextcloud/config/
RUN chmod +x /entrypoint.sh /cron.sh

VOLUME /var/www/html
ENTRYPOINT ["/entrypoint.sh"]
CMD ["apache2-foreground"]
