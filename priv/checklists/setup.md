# Setup

Set up the development environment for this project.

- [ ] Examine the project to understand what it is — language, framework, dependencies, services. Check README, existing Dockerfile, docker-compose.yml, Gemfile/package.json, Procfile, etc.
- [ ] Name the project
- [ ] Write a dev Dockerfile that installs everything the project needs. If the project already has a Dockerfile, adapt it for dev — don't start from scratch.
- [ ] Set the dev server command (one command that starts everything — e.g. bin/dev)
- [ ] Add any services the project needs (databases, caches) with the right images
- [ ] Set environment variables
- [ ] Rebuild (generates docker-compose.yml and starts everything)
- [ ] Verify ALL services are healthy — check logs, make sure each service accepts connections
- [ ] Install dependencies and run project setup via exec (migrations, seeds, etc.)
- [ ] Verify the dev server is running and responds
- [ ] Spawn a new agent named after the project, then ask the user if they'd like to keep Setup running

## How it works

The workspace tools (`set_dockerfile`, `set_dev_command`, `add_service`, etc.) write to `.boomlooper/repo/workspace.json`. When you call `rebuild`, a `docker-compose.yml` is generated from the config and `docker compose up --build` runs everything.

You get three types of containers:
- **workspace** — `sleep infinity`, full dev environment. Agents exec here.
- **dev** — runs your dev server command from the workspace image.
- **stock services** — postgres, redis, etc. from their own images.

## What is a service?

A **service** is something with a port that you connect to. It runs in its own Docker container.

A service is NOT a CSS watcher, JS bundler, or background worker. Those run inside the dev command.

If it doesn't have a port, it belongs inside the dev command.

## Rules

- Use the right image for services. If extensions are needed (pgvector, PostGIS), use a pre-built image.
- NEVER install extensions via runtime scripts — they don't persist across container restarts.
- The dev server should be ONE command that starts everything (bin/dev, foreman start, etc.).
