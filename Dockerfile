# FinTrack for hosting (Render, or any server that runs Docker).
# The PHP API and the pages run in one small container; the database is separate (Neon).
#   docker build -t fintrack .
#   docker run -p 10000:10000 -e DATABASE_URL=... -e JWT_SECRET=... fintrack
FROM php:8.3-cli-bookworm

# PostgreSQL driver for PHP (PDO), then remove the build tools again to keep the image small
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 libpq-dev \
 && docker-php-ext-install pdo_pgsql \
 && apt-get purge -y libpq-dev && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/* \
 && cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
 && printf 'expose_php = Off\ndisplay_errors = Off\nlog_errors = On\n' > "$PHP_INI_DIR/conf.d/fintrack.ini"

WORKDIR /app
COPY backend/src backend/src
COPY backend/bin backend/bin
COPY backend/router.php backend/router.php
COPY frontend frontend
COPY database database

# never run as root
RUN useradd --system --uid 10001 fintrack && chown -R fintrack /app
USER fintrack

WORKDIR /app/backend
# several workers, so one slow request doesn't hold up everyone else
ENV PHP_CLI_SERVER_WORKERS=4 \
    PORT=10000
EXPOSE 10000
CMD ["sh", "-c", "exec php -S 0.0.0.0:${PORT} -t ../frontend router.php"]
