# Generic Stack

No specific framework detected. General approach:

## Dockerfile

1. Pick a base image matching the project's language (`-slim` variant preferred)
2. `RUN apt-get update && apt-get install -y` system deps
3. `WORKDIR /workspace`
4. Do NOT `COPY . .` — code is in a volume

## Dev command

Look for:
- `Procfile.dev` or `Procfile` → use `foreman start` (install foreman in Dockerfile)
- `package.json` scripts → `npm run dev` or `npm start`
- `Makefile` → check for `dev` or `serve` target
- README → usually documents how to start

**Must bind `0.0.0.0`** — add `--host 0.0.0.0` or equivalent flag.

## After rebuild

1. Install dependencies inside the workspace container via `exec`
2. Set up database if needed (create, migrate)
3. Rebuild native extensions if coming from macOS: `npm rebuild`, etc.

## Gotchas

- macOS native binaries from the volume won't work — reinstall deps after rebuild
- Database URLs in `.env` files point to `localhost` — override with Docker service names via `set_env_vars`
