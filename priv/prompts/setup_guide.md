# Docker Compose Setup Guide

You are configuring a Docker Compose cluster using MCP tools. The cluster runs a development environment for a code project.

## Architecture

Your MCP tools write to a workspace config file. When you call `rebuild`, a `docker-compose.yml` is generated from that config and `docker compose up --build` runs.

The cluster has 3 types of containers:

- **workspace** — always running (`sleep infinity`). You `exec` commands here (install deps, run migrations, etc.)
- **dev** — runs the dev server command you set. Built from the same Dockerfile as workspace.
- **stock services** — postgres, redis, etc. Official images, no custom build.

All containers share a code volume mounted at `/workspace`.

## Your tools

| Tool | What it does |
|------|-------------|
| `set_dockerfile` | Set the Dockerfile content (dev image — system deps + language runtime) |
| `set_dev_command` | Set the dev server command AND its port |
| `add_service` | Add a stock service (postgres, redis, etc.) |
| `set_env_vars` | Set environment variables for workspace + dev containers |
| `set_workspace_name` | Name the project |
| `rebuild` | Generate compose file, build images, start all containers |
| `exec` | Run a command in the workspace container |
| `service_status` | Check which containers are running and healthy |
| `logs` | Read container logs |
| `ports` | Get mapped port numbers |

## Setup sequence

1. **Examine the project** — read key files (Gemfile, package.json, mix.exs, Dockerfile, Procfile.dev, README) to understand the stack
2. **Read the stack guide** — match to one of: `priv/prompts/stacks/rails.md`, `nextjs.md`, `phoenix.md`, `python.md`, `generic.md`. Read it for framework-specific patterns.
3. **Name the project** via `set_workspace_name`
4. **Write the Dockerfile** via `set_dockerfile` — a dev image that installs system deps and language runtime. Do NOT `COPY . .` — code is already at `/workspace` via volume mount.
5. **Set the dev command** via `set_dev_command` — the command that starts the dev server, AND its port
6. **Add services** via `add_service` — databases, caches the project needs
7. **Set env vars** via `set_env_vars` — database URLs, binding address, framework config
8. **Rebuild** via `rebuild` — this builds the image and starts everything. Dev server will likely crash on first boot (deps not installed, no database). That's expected — the crash logs tell you what to fix next.
9. **Install deps** via `exec` — `bundle install`, `npm install`, etc. inside the workspace container
10. **Run migrations** via `exec` — `bin/rails db:create db:migrate`, `npx prisma migrate dev`, etc.
11. **Rebuild again** via `rebuild` — restart the dev server now that deps and database are ready
12. **Check status** via `service_status` — verify containers are running and healthy
13. **Verify** via `ports` + `exec curl` — confirm the dev server responds on its port

## Critical rules

**Bind to 0.0.0.0** — Dev servers MUST bind to `0.0.0.0`, not localhost. Docker port mapping can't reach localhost inside a container. Set `BINDING=0.0.0.0` env var or add `-b 0.0.0.0` / `-H 0.0.0.0` / `--host 0.0.0.0` to the dev command.

**Declare ports** — Every HTTP process must have its port declared in `set_dev_command`. Only specify the container port (e.g. `"3000"`). Docker picks the host port automatically.

**Don't COPY code** — The Dockerfile should NOT copy project files. Code lives in a volume at `/workspace`. The Dockerfile just sets up the environment (apt packages, language runtime, build tools).

**Split heavy Dockerfile layers** — Don't install everything in one giant `RUN apt-get install`. Split into separate layers: (1) core build tools + language runtime, (2) optional heavy packages like Chromium/headless browsers, (3) fonts/media libraries. Each `RUN` is a separate Docker build step — if one OOM-kills, you lose the whole layer. Smaller layers cache better and survive memory-constrained builds.

**Platform: Linux ARM64** — Containers run on Apple Silicon. Use multi-arch images. Prefer `-slim` variants. If an image has no ARM64 build, find an alternative.

**One rebuild, then exec** — Rebuild creates the containers. After that, install deps and run migrations via `exec`. Don't rebuild just to install packages — that restarts everything.

**Dev server crashes are diagnostic, not failures.** The dev container starts during rebuild, but deps aren't installed and the database doesn't exist yet. The first crash is expected. Read the crash logs from the post-rebuild status — they tell you exactly what to fix:

- "cannot load such file" / "ModuleNotFoundError" → run `exec: bundle install` / `pip install`
- "relation does not exist" / "database does not exist" → run `exec: rails db:create db:migrate`
- "Could not find gem" → run `exec: bundle install`
- "ENOENT: Procfile.dev" → check if the file exists, adjust the dev command

**The fix loop:** read crash log → `exec` to fix → `rebuild` to restart dev → read new crash log → repeat. It may take several iterations — each crash reveals the next issue. First crash: missing deps. Second crash: missing database. Third crash: missing env var. This is normal. Do NOT change the Dockerfile or service config in response to a dev crash — those are runtime issues, not build issues. Use `exec` to fix them, then `rebuild` to restart dev and see if the next issue surfaces.

**Check status once** — After rebuild, call `service_status` once. Don't poll in a loop. If something crashed, read `logs` and fix the config.

**Database URLs use service names** — In Docker Compose, services reach each other by name. Postgres URL: `postgres://postgres@postgres:5432/myapp_dev`. Redis: `redis://redis:6379/0`.

**Service env vars go on the service** — `set_env_vars` sets env vars for workspace + dev containers. Service-specific env vars (like `POSTGRES_HOST_AUTH_METHOD=trust` for postgres) must be passed via the `env` parameter of `add_service`. If postgres won't start, this is almost certainly the reason.
