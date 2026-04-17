# Laravel / PHP

## Discovering it's Laravel

You're looking at a Laravel project if the repo has any of:
- `composer.json` with `"laravel/framework"` in `require`
- `artisan` file at the repo root
- `app/Http/Controllers/`
- `bootstrap/app.php`

For non-Laravel PHP (Symfony, plain), the same Dockerfile pattern works — swap the dev command.

## Dockerfile

```dockerfile
FROM php:8.3-cli

# System deps + common PHP extension prerequisites
RUN apt-get update && apt-get install -y \
    git curl unzip ca-certificates \
    libzip-dev libpng-dev libonig-dev libxml2-dev libsqlite3-dev \
    libpq-dev libicu-dev libjpeg-dev libfreetype6-dev \
    && rm -rf /var/lib/apt/lists/*

# Compile common PHP extensions Laravel apps need.
# Install in one RUN so they share the configure step.
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
       pdo_mysql pdo_pgsql pdo_sqlite mbstring exif pcntl bcmath gd zip intl

# Composer (single static binary, official installer)
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Node for Vite asset compilation (Laravel 9+ with Breeze/Jetstream)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
```

**Check `composer.json`** for `require.php` constraint — if it requires `^8.1` or `^8.2`, switch the FROM tag accordingly. Common: `php:8.1-cli`, `php:8.2-cli`, `php:8.3-cli`.

**Check `composer.json` `require` for app-specific extensions** — adjust the `docker-php-ext-install` line:
- `ext-gmp` → install `libgmp-dev` and add `gmp` to ext-install
- `ext-soap` → install `libxml2-dev` and add `soap`
- `ext-redis` → install via `pecl install redis && docker-php-ext-enable redis` (it's a PECL ext)
- `ext-imagick` → install `libmagickwand-dev` and `pecl install imagick && docker-php-ext-enable imagick`

## Dev command

Two main options. Pick the simpler one (`php artisan serve`) unless the app explicitly needs the others:

```yaml
# Simple — single PHP process, port 8000 by default
command: php artisan serve --host=0.0.0.0 --port=8000
```

If the project uses **Vite** (most Laravel 9+ apps with Breeze/Jetstream/Inertia):

```yaml
# Two-process: PHP server + Vite dev server. Use a small wrapper script.
command: sh -c "php artisan serve --host=0.0.0.0 --port=8000 & npm run dev -- --host=0.0.0.0 & wait"
```

For an Octane (Swoole/RoadRunner) app, the `composer.json` will list `laravel/octane`:

```yaml
command: php artisan octane:start --host=0.0.0.0 --port=8000
```

**Always pass `--host=0.0.0.0`** — `php artisan serve` defaults to `127.0.0.1` and the eval runner can't reach it from the host.

## Services

In docker-compose.yml, add stock services as needed:

- **mysql** (most common Laravel default):
  ```yaml
  mysql:
    image: mysql:8
    environment:
      - MYSQL_ALLOW_EMPTY_PASSWORD=yes
      - MYSQL_DATABASE=laravel
    volumes:
      - mysql-data:/var/lib/mysql
  ```
- **postgres** (if `config/database.php` lists `pgsql` as default, or `.env.example` has `DB_CONNECTION=pgsql`):
  ```yaml
  postgres:
    image: postgres:16
    environment:
      - POSTGRES_HOST_AUTH_METHOD=trust
      - POSTGRES_DB=laravel
    volumes:
      - postgres-data:/var/lib/postgresql/data
  ```
- **redis** (if Gemfile has `redis` or `predis/predis` is in composer.json, or queue/cache uses redis):
  ```yaml
  redis:
    image: redis:7-alpine
  ```
- **mailpit** (Laravel ships with mailpit support — `config/mail.php` likely uses it):
  ```yaml
  mailpit:
    image: axllent/mailpit
  ```

## Env vars

```
APP_ENV=local
APP_DEBUG=true
APP_KEY=                          # set after `php artisan key:generate`
APP_URL=http://localhost:8000
DB_CONNECTION=mysql               # or pgsql / sqlite
DB_HOST=mysql
DB_PORT=3306
DB_DATABASE=laravel
DB_USERNAME=root
DB_PASSWORD=
REDIS_HOST=redis
MAIL_HOST=mailpit
MAIL_PORT=1025
```

For **Postgres** instead of MySQL:
```
DB_CONNECTION=pgsql
DB_HOST=postgres
DB_PORT=5432
DB_USERNAME=postgres
DB_PASSWORD=
```

If the project has `.env.example`, copy it as a starting point, then override the DB host to point at the compose service name (`mysql` / `postgres`), not `127.0.0.1`.

## After docker_compose up

```
exec("cp .env.example .env")              # if .env doesn't exist
exec("composer install --no-interaction")  # install PHP deps
exec("php artisan key:generate")          # generate APP_KEY
exec("php artisan migrate")               # run migrations
exec("php artisan db:seed")               # seed (only if seeders exist + project expects them)
exec("npm install && npm run build")      # build assets (skip if app doesn't use Vite)
```

If the project has a custom setup script (look for `bin/setup`, `scripts/install.sh`, or notes in README), prefer that.

## Gotchas

- **APP_KEY required.** Laravel refuses to start without it. `php artisan key:generate` writes it to `.env`. If `.env` doesn't exist, copy `.env.example` first.
- **Storage permissions.** `storage/` and `bootstrap/cache/` need to be writable. The container runs as root by default which is fine, but if you build a non-root user image you'll need `chown`.
- **`php artisan serve` is single-threaded.** That's fine for an eval — concurrent connections aren't needed. For a real dev server use Octane or php-fpm + nginx.
- **Vite dev server runs separately on port 5173** by default. The Laravel app reads `vite/manifest.json` at request time. If you only run `php artisan serve` without `npm run dev` or a build, the page will 500 with a Vite manifest error. Either run BOTH processes (use the wrapper command above) or run `npm run build` once during setup so a static manifest exists.
- **Sail conflicts.** Many Laravel apps ship `docker-compose.yml` from Laravel Sail. Don't use it as-is — Sail expects specific user IDs and a `sail` CLI wrapper. Write a fresh compose file using the template above.
- **Octane needs a separate worker.** If using Octane, the `command:` for the dev service runs the Octane server directly — no separate `php artisan serve`.
