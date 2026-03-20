# Setup

Set up the development environment for this project.

- [ ] Examine the project to understand what language, framework, tools, and services it needs. If the project has an existing Dockerfile, use it as a starting point for the dev Dockerfile — don't reinvent what's already there. Check for database extensions, search engines, or other dependencies in config files (Gemfile, requirements.txt, schema files, docker-compose.yml).
- [ ] Name the project
- [ ] Write a dev Dockerfile that installs everything the project needs
- [ ] Set the dev server command (one command that starts everything — e.g. bin/dev)
- [ ] Add any services the project needs (databases, caches, etc.) — use the right image for each. If the project needs database extensions (e.g. pgvector, PostGIS), use an image that includes them (e.g. `pgvector/pgvector:pg16` instead of `postgres:16`).
- [ ] Set environment variables
- [ ] Build the Docker image
- [ ] Start all services
- [ ] Verify ALL services are healthy — check each service's logs, make sure it's accepting connections. If a service crashes, read the logs, figure out why (missing extension, bad config, wrong image), fix it, and restart.
- [ ] Install dependencies and run project setup (migrations, seeds, etc.)
- [ ] Verify the dev server is running and responds
- [ ] Spawn a new agent named after the project, then ask the user if they'd like to keep Setup running

## What is a service?

A **service** is something with a port that you connect to. It runs in its own Docker container.
- postgres on 5432, redis on 6379, the dev server on 3000, elasticsearch on 9200
- Each gets its own container, its own `docker logs`, its own lifecycle
- Use the right image — if the project needs extensions (pgvector, PostGIS, redis modules), find an image that includes them instead of the stock image

A service is NOT:
- A CSS watcher, JS bundler, or background worker — those are internal to the dev command
- Anything from a Procfile — the Procfile runs INSIDE the dev container via `bin/dev` or `foreman start`

If it doesn't have a port, it's not a service — it belongs inside the dev command.
