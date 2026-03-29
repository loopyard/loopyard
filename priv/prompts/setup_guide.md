# Setup Guide

## How BoomLooper Works

**Architecture:** Two containers share a code volume:
- **Workspace container** (alpine + git) — always running, you exec commands here
- **Dev container** (built from your Dockerfile) — runs the app, hot reloads via inotify

Your config goes in `.boomlooper/repo/workspace.json`. This gets written via MCP tools (`set_dockerfile`, `set_dev_command`, etc.). BoomLooper generates the actual Dockerfile and docker-compose.yml from your config.

**Project root files are clues, not config.** The project may have:
- `Dockerfile` — production image, usually not suitable for dev
- `docker-compose.yml` — may be useful, but often production-focused
- `.env` — project runtime config, BoomLooper overrides this with env_vars
- `Procfile.dev` — shows how the project runs locally

Read these to understand the project. Use them as hints. But your final config goes through the MCP tools, not by copying project files.

## Ruby/Rails Recipe

### Dockerfile

**Important:** Code lives in a Docker volume mounted at `/workspace`. The Dockerfile builds the dev environment image, NOT the app. Don't use `COPY` or `ADD` for project files — they're not in the build context.

```dockerfile
FROM ruby:3.4.2-slim

RUN apt-get update && apt-get install -y \
    build-essential libpq-dev libsqlite3-dev libyaml-dev libssl-dev git curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
```

**Adjust for project needs:**
- If using libvips (image processing): add `libvips-dev` to apt-get
- If using Node.js: install via nodesource script
- If using `bin/dev` (Procfile.dev exists): add `RUN gem install foreman` after apt-get

### Dev command

**Boot with 1 worker and bind to 0.0.0.0 (external port).** Apps must not bind to localhost — Docker can't forward to localhost bindings.

BoomLooper automatically runs `bundle install` and `db:prepare` before Ruby commands, so just set the dev command:

- If project has `Procfile.dev`: use `bin/dev`
- Otherwise: use `bin/rails server --port $PORT --binding 0.0.0.0`

### Env vars

Set: `HOTSWAP_DISABLED=1`, `HOST=0.0.0.0`

## Workflow

### Phase 1: Examine the project

Read project files to understand what you're working with:
- `Gemfile` — Ruby version, key gems (Rails version, database adapter, asset pipeline)
- `Procfile.dev` — how the project runs locally (if exists, you'll need foreman)
- `config/database.yml` — what database it expects
- `.ruby-version` or `.tool-versions` — Ruby version to use in FROM line
- `package.json` — whether Node.js is needed

### Phase 2: Plan the setup

Based on what you found:
1. **Base image** — match Ruby version from project
2. **System deps** — what apt packages are needed (libpq-dev for postgres, libvips-dev for image processing, etc.)
3. **Runtime deps** — does it need Node.js? foreman?
4. **Dev command** — `bin/dev` if Procfile.dev exists, otherwise direct rails server
5. **Services** — postgres, redis, etc. based on database.yml and Gemfile

### Phase 3: Configure

1. `set_dockerfile` — based on your plan
2. `set_dev_command` — usually `bin/dev` or `bin/rails server --binding 0.0.0.0 --port $PORT`
3. `set_env_vars` — HOTSWAP_DISABLED=1, HOST=0.0.0.0
4. `add_service` — postgres, redis, etc. with proper env vars:
   - Postgres: `{"POSTGRES_HOST_AUTH_METHOD": "trust"}` (allows passwordless local dev)
   - Redis: no special env needed

### Phase 4: Build and verify

1. `rebuild` — **tell the human this may take 2-5 minutes**. This builds the dev container image.
2. Check `service_status` once per minute. Report status to human each time.
3. Wait for dev container to become healthy — BoomLooper automatically runs `bundle install` and `db:prepare` on startup.

**Don't spam service_status.** Check once, wait a minute, check again. Builds take time.
