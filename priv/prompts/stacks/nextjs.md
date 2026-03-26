# Next.js Stack Guide

## Base image

Use `node:22-slim` or `node:20-slim`. These are cached locally.

**Version lock:** Check `.nvmrc` or `.node-version`. If it doesn't match, update it after first rebuild: `exec`: `echo "22" > .nvmrc`

## Dockerfile pattern

```dockerfile
FROM node:22-slim

RUN apt-get update && apt-get install -y \
    git curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
```

## Dev command

Usually `npm run dev` or `yarn dev`. Default port is 3000.

`set_dev_command` with `command: "npm run dev"`, `ports: ["3000"]`.

## Services

- **PostgreSQL** (if using Prisma/Drizzle with postgres): `postgres:16` with `POSTGRES_HOST_AUTH_METHOD=trust`
- **Env vars:** `DATABASE_URL=postgres://postgres@postgres:5432/<app>_dev`, `NODE_ENV=development`

## After rebuild

```
exec: npm install        # gets Linux native binaries
exec: npx prisma migrate dev   # if using Prisma
exec: npx prisma generate      # if using Prisma
```

## Common gotchas

- **node_modules clobbering:** Host macOS `node_modules` has wrong binaries. `npm install` inside the container fixes it — the bind mount means the container's install overwrites the host's.
- **sharp/esbuild/swc:** Platform-specific. `npm rebuild` if they crash with "Exec format error".
- **.env.local:** Next.js reads `.env.local` for env vars. If database URLs are set there, they'll point to `localhost` not the docker service name. Override via `set_env_vars`.
- **Polling:** Set `WATCHPACK_POLLING=true` for webpack/Next.js file watching.
