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

The project directory is bind-mounted at /workspace at runtime. Only copy dependency manifests in the Dockerfile — NOT the full source.

Pattern:
1. `FROM <language>:<version>-slim`
2. `RUN apt-get update && apt-get install -y <system packages>`
3. Copy dependency lockfiles, install deps
4. `WORKDIR /workspace`

**Do NOT `COPY . .`** — the bind mount overlays it.

## Library path clobbering

Host macOS binaries in bind-mounted dirs crash on Linux. Redirect platform-specific artifacts outside /workspace via ENV vars in the Dockerfile. Read the stack guide for specifics.

## Unix sockets don't work across bind mounts

If a library creates Unix sockets in `/workspace/tmp/`, it fails with ENOTSUP. Disable via env vars or redirect socket paths outside /workspace. Stack guides list common culprits.

## File watchers need polling

inotify/fsevents don't work across bind mounts. Always use polling:
- Tailwind CSS v4+: `TAILWINDCSS_POLL=true`
- Webpack: `--watch-poll`
- Vite: `server.watch.usePolling: true`
- General: if "watchman: not found", use polling — do NOT install watchman.

## Ports

Every HTTP process MUST have ports set via `set_dev_command`. Only specify the container port — Docker picks the host port. Never use `"3001:3000"` format.

## Rebuilds

`rebuild` streams build output. After it finishes, call `service_status` ONCE. Never poll in a loop. Never use `sleep`. If containers don't appear, read the build output and fix the Dockerfile.

## Verification

Do NOT check off verification items until they actually pass:
- "Services healthy" = `service_status` shows `running: true` and `health: healthy`
- "Dev server responds" = confirmed port is listening via `ports` tool
- If dev crashed, check logs, fix, rebuild. Not done until serving requests.

## When things go wrong

Read the error. Fix the Dockerfile or config. Rebuild. If database schema is broken, drop and recreate — don't debug stale schemas.
