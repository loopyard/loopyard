# Setup Agent Guide

## Step 1: Identify the stack

Read the project files first. Then read the matching stack guide from `/workspace/.boomlooper/` or use `exec` to `cat` the guide from the BoomLooper priv directory:

- Gemfile → Rails → read `priv/prompts/stacks/rails.md` via `Read` tool at the BoomLooper project root
- package.json with "next" → Next.js → read `priv/prompts/stacks/nextjs.md`
- mix.exs → Phoenix → read `priv/prompts/stacks/phoenix.md`
- requirements.txt / pyproject.toml → Python → read `priv/prompts/stacks/python.md`
- No match → read `priv/prompts/stacks/generic.md`

The stack guide has framework-specific Dockerfile patterns, database setup, gotchas.

## Platform & architecture

The host is macOS (likely Apple Silicon / ARM64). Containers run Linux ARM64.
- Use official multi-arch Docker images.
- Prefer `apt-get install` over building from source.
- Never download x86_64 binaries.

**Use these cached base images:** `ruby:3.4.8-slim`, `node:22-slim`, `python:3.12-slim`. Other versions may hang on pull.

**Service images must have ARM64 support.** If "no matching manifest for linux/arm64" appears, find an alternative image.

## The Dockerfile is a DEV image

The project code lives in a Docker volume mounted at /workspace. Only copy dependency manifests in the Dockerfile — NOT the full source.

Pattern:
1. `FROM <language>:<version>-slim`
2. `RUN apt-get update && apt-get install -y <system packages>`
3. Copy dependency lockfiles, install deps
4. `WORKDIR /workspace`

**Do NOT `COPY . .`** — the volume mount overlays it.

## Library path clobbering

Host macOS binaries copied into the volume crash on Linux. Redirect platform-specific artifacts outside /workspace via ENV vars in the Dockerfile. Read the stack guide for specifics (e.g. `BUNDLE_PATH`, `node_modules` rebuild).

## Ports & binding

Every HTTP process MUST have ports set via `set_dev_command`. Only specify the container port — Docker picks the host port. Never use `"3001:3000"` format.

**The dev server MUST bind to `0.0.0.0`**, not `localhost` or `127.0.0.1`. If it binds to localhost, Docker port mapping can't reach it from outside the container. This is the #1 reason "the server is running but I can't reach it."

Common fixes:
- **Rails:** `bin/rails server -b 0.0.0.0` (add `-b 0.0.0.0` to the server command in Procfile.dev or set `BINDING=0.0.0.0`)
- **Next.js / Node:** `next dev -H 0.0.0.0` or `HOST=0.0.0.0`
- **Phoenix:** Already binds to `0.0.0.0` in dev by default (via `config/dev.exs`)
- **Python (Django/Flask/uvicorn):** `--host 0.0.0.0`
- **Vite:** `--host 0.0.0.0`

Set this via env var (`BINDING=0.0.0.0`) or in the dev command itself. Check Procfile.dev — if the server command doesn't include a bind flag, add one.

## Rebuilds

`rebuild` streams build output. After it finishes, call `service_status` ONCE. Never poll in a loop. Never use `sleep`. If containers don't appear, read the build output and fix the Dockerfile.

## Verification

Do NOT check off verification items until they actually pass:
- "Services healthy" = `service_status` shows `running: true` and `health: healthy`
- "Dev server responds" = confirmed port is listening via `ports` tool
- If dev crashed, check logs, fix, rebuild. Not done until serving requests.

## When things go wrong

Read the error. Fix the Dockerfile or config. Rebuild. If database schema is broken, drop and recreate — don't debug stale schemas.
