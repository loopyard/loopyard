# Setup

Set up the development environment for this project.

- [x] Examine the project to understand what language, framework, tools, and services it needs
- [x] Name the workspace
- [x] Write a dev Dockerfile that installs everything the project needs
- [x] Set the dev server command (one command that starts everything — e.g. bin/dev)
- [x] Add any services the project needs (databases, caches, etc.)
- [x] Set environment variables
- [x] Build the Docker image
- [x] Start all services
- [x] Install dependencies and run project setup (migrations, seeds, etc.)
- [x] Verify the dev server is running and responds
- [x] Spawn a new agent named after the project, then ask the user if they'd like to keep Setup running

## What is a service?

A **service** is something with a port that you connect to. It runs in its own Docker container.
- postgres on 5432, redis on 6379, the dev server on 3000, elasticsearch on 9200
- Each gets its own container, its own `docker logs`, its own lifecycle

A service is NOT:
- A CSS watcher, JS bundler, or background worker — those are internal to the dev command
- Anything from a Procfile — the Procfile runs INSIDE the dev container via `bin/dev` or `foreman start`

If it doesn't have a port, it's not a service — it belongs inside the dev command.
