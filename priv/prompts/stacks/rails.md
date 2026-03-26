# Rails Stack Guide

## Base image

Use `ruby:3.4.8-slim`. This is cached locally.

**Version lock files:** If `.ruby-version` doesn't match the container ruby, Bundler crashes. Fix after first rebuild:
1. `exec`: `echo "3.4.8" > .ruby-version`
2. Rebuild again

## Dockerfile pattern

```dockerfile
FROM ruby:3.4.8-slim

RUN apt-get update && apt-get install -y \
    build-essential git curl \
    libpq-dev libyaml-dev pkg-config \
    nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# Redirect bundle path to avoid clobbering host gems
ENV BUNDLE_PATH=/usr/local/bundle

WORKDIR /workspace
```

Check `Gemfile` for extras:
- `pg` → add `libpq-dev`
- `image_processing` → add `libvips` or `imagemagick`
- `nokogiri` → add `libxml2-dev libxslt-dev`
- PostGIS (`rgeo`, `activerecord-postgis-adapter`) → add `libproj-dev proj-bin`
- `yt-dlp` or `ffmpeg` references → add `ffmpeg`

## Dev command

Usually `bin/dev` (foreman). Check `Procfile.dev` to see what it runs. Default port is 3000.

`set_dev_command` with `command: "bin/dev"`, `ports: ["3000"]`.

If `Procfile.dev` references a non-standard port (e.g. `PORT=5000`), use that port instead.

## Services

- **PostgreSQL:** Use `postgres:16` for plain postgres. Use `postgis/postgis:16-3.4` if the app uses PostGIS. If it also needs pgvector, you may need to install it via Dockerfile or find a combined image.
- **Redis:** `redis:7-alpine`
- **Env vars:** `POSTGRES_HOST_AUTH_METHOD=trust` for postgres. `DATABASE_URL=postgres://postgres@postgres:5432/<app>_development`. `REDIS_URL=redis://redis:6379/0`.

## After rebuild

```
exec: bundle install
exec: npm install && npm rebuild   # rebuilds native extensions for Linux
exec: bin/rails db:create
exec: bin/rails db:migrate
exec: bin/rails db:seed            # optional, may fail on bad seed data — skip if it errors
```

If db:migrate fails with schema errors, start fresh: `bin/rails db:drop db:create db:migrate`.

## Common gotchas

- **Bundle path clobbering:** Host `vendor/bundle` has macOS gems. Set `ENV BUNDLE_PATH=/usr/local/bundle` in Dockerfile.
- **Spring/Hotswap sockets:** Fail on bind mounts. Set `DISABLE_SPRING=1` and `HOTSWAP_DISABLED=1` env vars.
- **Tailwind CSS polling:** Set `TAILWINDCSS_POLL=true` env var. Do NOT install watchman.
- **esbuild/node binaries:** Host `node_modules` has macOS binaries. `npm rebuild` after rebuild fixes this.
- **foreman not found:** Add `RUN gem install foreman` to Dockerfile.
