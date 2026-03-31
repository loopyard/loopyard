# Rails

## Dockerfile

```dockerfile
FROM ruby:3.4.8-slim
RUN apt-get update && apt-get install -y \
    build-essential git curl libpq-dev libyaml-dev pkg-config nodejs npm \
    && rm -rf /var/lib/apt/lists/*
RUN gem install foreman
ENV BUNDLE_PATH=/usr/local/bundle
WORKDIR /workspace
```

Check `.ruby-version` — if it doesn't match 3.4.8, update the FROM tag or write the matching version to `.ruby-version` after first rebuild.

Check `Gemfile` for extras: `image_processing` → add `libvips`, `nokogiri` → add `libxml2-dev libxslt-dev`, PostGIS → add `libproj-dev`.

## Dev command

`bin/dev` (uses foreman + Procfile.dev). Port is usually `3000`. Check Procfile.dev for the actual port.

## Services

- **postgres:** `postgres:16` with `POSTGRES_HOST_AUTH_METHOD=trust`
- **redis:** `redis:7-alpine` (if Gemfile has `redis` or `sidekiq` or `good_job`)

## Env vars

```
BINDING=0.0.0.0
DATABASE_URL=postgres://postgres@postgres:5432/<app>_development
REDIS_URL=redis://redis:6379/0
DISABLE_SPRING=1
BUNDLE_PATH=/usr/local/bundle
```

## After rebuild

```
exec: bundle install
exec: npm install && npm rebuild
exec: bin/rails db:create
exec: bin/rails db:migrate
```

If db:migrate fails with schema errors: `bin/rails db:drop db:create db:migrate`

## Gotchas

- `BUNDLE_PATH=/usr/local/bundle` in Dockerfile prevents macOS gems from being used
- `npm rebuild` fixes native extensions (esbuild, sharp) built for wrong platform
- `foreman` must be installed in Dockerfile (`gem install foreman`) — it's not in the bundle
