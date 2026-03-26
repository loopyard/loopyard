# Setup Agent Guide

## Platform & architecture

The host machine is macOS (likely Apple Silicon / ARM64). The container runs Linux ARM64 (aarch64).
- Always use official multi-arch Docker images — they have ARM64 variants.
- Prefer `apt-get install <package>` over building from source.
- Never download x86_64 binaries.

**Use these exact image tags for base images:**
- Ruby: `ruby:3.4.8-slim`
- Node: `node:22-slim` or `node:20-slim`
- Python: `python:3.12-slim`

These specific versions are cached locally. Do NOT use the version from the project's existing Dockerfile — those versions may not be cached, and Docker Hub pulls hang. Always use the versions listed above.

**Version lock files must match the container.** If you use `ruby:3.4.8-slim` but the project's `.ruby-version` says `3.4.2`, Bundler will crash with version mismatch. Fix this after the first rebuild:
1. First `rebuild` creates containers (dev may crash, that's expected)
2. `exec` into workspace: `echo "3.4.8" > .ruby-version`
3. Second `rebuild` to restart dev with correct version

Same pattern for Node with `.nvmrc` or `.node-version` files.

**Service images must have ARM64 support.** Before calling `add_service`, verify the image has an ARM64 build. If "no matching manifest for linux/arm64" appears during rebuild, find an alternative image.

**JS bundler binaries** (esbuild, swc, sharp, etc.) are platform-specific. If the project has `node_modules` on the host (macOS), those binaries won't work in the Linux container. Fix: `exec` with `npm rebuild` or `npm install` after rebuild to get Linux binaries.

## The Dockerfile is a DEV image, not a production deploy

The project directory is bind-mounted into the container at /workspace at RUNTIME. The Docker build context is the project root, so `COPY` works for dependency manifests.

Good dev Dockerfile pattern:
1. `FROM ruby:3.4` (or whatever language image)
2. `RUN apt-get update && apt-get install -y <system packages>`
3. `COPY Gemfile Gemfile.lock ./` then `RUN bundle install` — pre-installs deps in the image layer
4. `WORKDIR /workspace`

**Do NOT `COPY . .`** — pointless since the bind mount overlays it at runtime. Only copy dependency manifests.

After rebuild, use `exec` for runtime setup:
- Create databases: `exec` with `rails db:create` or `createdb`
- Run migrations: `exec` with `rails db:migrate` or equivalent
- Install JS deps: `exec` with `npm install` or `yarn install`
- Build assets: `exec` with the project's asset build command

## Library path clobbering

The host project directory (macOS) is bind-mounted into the container (Linux) at /workspace. If the project has compiled dependencies in a subdirectory (vendor/bundle, node_modules, etc.), the host's macOS-compiled binaries will crash on Linux.

**The principle:** Any directory with platform-specific compiled artifacts must be redirected OUTSIDE /workspace via ENV vars in the Dockerfile.

How to figure this out:
1. Read dependency config files (.bundle/config, .npmrc, pip.conf)
2. Check if deps install into a project subdirectory
3. If yes, set an ENV var to redirect to a system path

Common examples:
- Ruby: check `.bundle/config` for `BUNDLE_PATH`. Override with `ENV BUNDLE_PATH=/usr/local/bundle`
- Node: `npm install` inside the container overwrites host copies with Linux versions — usually fine
- Python: override with `ENV VIRTUAL_ENV=/opt/venv`

## Unix sockets don't work across bind mounts

If a library tries to create a Unix socket in `/workspace/tmp/` or any bind-mounted path, it will fail with `ENOTSUP` or `Operation not supported`. Common culprits:
- **hotswap** (Rails): set `HOTSWAP_DISABLED=1` env var
- **spring** (Rails): set `DISABLE_SPRING=1` env var
- Any library using `/tmp/sockets/` inside the project

Fix: Disable the library via env var, or redirect socket paths outside /workspace.

## File watchers and bind mounts

inotify/fsevents do NOT work across Docker bind mounts. Always use polling mode:
- Tailwind CSS v4+: set `TAILWINDCSS_POLL=true` env var (via `set_env_vars`)
- Tailwind CSS v3: `tailwindcss --watch --poll`
- Webpack: `webpack --watch --watch-poll`
- Vite: `server.watch.usePolling: true`
- Nodemon: `nodemon --legacy-watch`
- Rails: if tailwindcss-rails is used, set `TAILWINDCSS_POLL=true`. Do NOT install watchman.
- General: if you see "watchman: not found" in logs, the fix is polling mode, NOT installing watchman.

## Ports

Every process that serves HTTP MUST have ports set. Use `set_dev_command` with ports.

When calling `set_dev_command`, always include the port the dev server listens on:
- Rails on port 3000: `ports: ["3000"]`
- Phoenix on port 4000: `ports: ["4000"]`
- Next.js on port 3000: `ports: ["3000"]`

Only specify the container port — Docker picks a free host port automatically. Never use host:container format like `"3001:3000"`.

## Rebuilds and waiting

**`rebuild` returns immediately** — the build runs in the background. You'll see build output streaming in `build` role messages. Wait for build completion before checking containers.

How to know the build finished:
1. Look for build output messages showing "Successfully built" or container start logs
2. Call `service_status` ONCE — if services appear, you're good
3. If `service_status` returns empty, check `logs` for the workspace container to see build errors

**NEVER poll in a loop.** If containers don't appear after one `service_status` check:
- Read the build output messages for errors
- Use `logs` tool to check container logs
- Fix the Dockerfile and rebuild if needed

- **NEVER use `sleep` or `exec sleep`.**
- If `exec` returns "No such container", STOP — read the build output, fix the Dockerfile, and rebuild.
- **NEVER retry the same failing command.**

## Verification requirements

**Do NOT check off verification items until they actually pass.**

- "Verify dev server is running" means `service_status` shows `"running":true` and `"health":"healthy"` for dev. NOT just that containers exist.
- "Verify dev server responds" means you confirmed port is listening (via `ports` tool or curl). NOT just assuming it works.
- If dev shows `"health":"crashed"`, check logs, fix the issue (usually missing deps or wrong ruby version), rebuild, and keep trying until healthy.

**The eval is not done until the dev server is actually serving requests.**

## When things go wrong

If the build fails, read the error output. Fix the Dockerfile. Rebuild.

When explaining problems to the user, the abstraction has leaked. Your job:
1. Name the abstraction — "Your project runs in a Linux container, code shared via folder mount"
2. Explain why it matters for their specific problem
3. Tell them what you're doing to fix it
4. If stuck, give them context to search for a solution
