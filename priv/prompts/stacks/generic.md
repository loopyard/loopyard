# Generic Stack Guide

No specific framework detected. Use these general principles.

## Dockerfile pattern

1. Pick a base image that matches the project's language
2. Install system deps via `apt-get`
3. Copy dependency lockfiles and install
4. `WORKDIR /workspace`

## Dev command

Look for:
- `Procfile.dev` or `Procfile` → use `foreman start` (install foreman in Dockerfile)
- `package.json` scripts → `npm run dev` or `npm start`
- `Makefile` → check for a `dev` or `serve` target
- README → usually documents how to start the dev server

## After rebuild

1. Install dependencies (`npm install`, `pip install`, `bundle install`, etc.)
2. Set up database if needed (create, migrate)
3. Build assets if needed

## Common gotchas

- Host native binaries don't work in the container — reinstall deps after rebuild
- File watchers need polling mode in bind mounts
- Database URLs in .env files point to localhost — override with docker service names via `set_env_vars`
