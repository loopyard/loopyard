# Node (generic — Express, Fastify, Hono, NestJS, plain HTTP)

This is the **non-Next.js Node web app** guide. If the project has `next` in dependencies, use `nextjs.md` instead.

## Discovering it's a Node web app

You're looking at a Node web app if:
- `package.json` exists
- `dependencies` lists one of: `express`, `fastify`, `koa`, `hono`, `@nestjs/core`, `restify`, `polka`, `h3`
- `scripts.dev` or `scripts.start` exists, often something like `node server.js`, `nodemon`, `tsx watch`, `ts-node-dev`, or `nest start --watch`

For TypeScript-only projects you'll also see `typescript`, `@types/node`, and a `tsconfig.json`.

## Dockerfile

```dockerfile
FROM node:22-slim

RUN apt-get update && apt-get install -y \
    git curl ca-certificates python3 build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# pnpm via corepack — many Node apps now ship with pnpm-lock.yaml
RUN corepack enable
```

**Check the lockfile** to pick the package manager:
- `package-lock.json` → npm (default)
- `yarn.lock` → yarn (`corepack enable` already supports it)
- `pnpm-lock.yaml` → pnpm
- `bun.lockb` → bun (use `oven/bun:1` as the base image instead — see Bun section)

**Check `engines.node` in package.json** — if it requires `>=20`, `node:22-slim` is fine; if it requires `^18`, switch to `node:18-slim`.

**`python3` + `build-essential`** are there for `node-gyp` builds (needed by `bcrypt`, `sqlite3`, `node-sass`, etc.). Skip them if the project clearly doesn't have native deps.

## Dev command

In docker-compose.yml:

```yaml
dev:
  build: .
  command: npm run dev      # or: pnpm dev / yarn dev
  ports:
    - "3000"
  volumes:
    - code:/workspace
  working_dir: /workspace
```

The actual port depends on the project. Read `package.json` `scripts.dev` and any `server.ts` / `app.js` to find the listen port. Common defaults:

- Express / Koa / Hono: `3000`
- Fastify: `3000`
- NestJS: `3000`
- Strapi: `1337`
- Adonis: `3333`
- Sails: `1337`

## Bind to 0.0.0.0

Most Node frameworks default to `127.0.0.1` and will be unreachable from the host. Fix at the framework level:

- **Express / Koa / Hono / Fastify**: `app.listen(port, '0.0.0.0')`. If the project's `server.ts` says `app.listen(3000)` (no host arg), it'll bind to `127.0.0.1` on Linux. **Don't edit the project's source** — instead, set the host via env var if the framework reads one (`HOST=0.0.0.0`, `BIND=0.0.0.0`), OR add a `--host 0.0.0.0` flag if the dev script supports it.
- **NestJS**: `app.listen(3000, '0.0.0.0')` — same issue. Set `HOST=0.0.0.0` and check if the bootstrap reads it.
- **Vite middleware mode**: `server.host: '0.0.0.0'` or pass `--host 0.0.0.0` to vite.
- **`tsx watch` / `nodemon` / `ts-node-dev`**: just wrappers; the underlying server's bind address is what matters.

If the project really binds to localhost in source and you can't override via env, the cleanest fix is to **add a tiny entrypoint** that overrides via env:

```yaml
command: sh -c "HOST=0.0.0.0 npm run dev"
```

Many Node apps DO read `process.env.HOST` even when the docs don't say so.

## Services

Add to docker-compose.yml only what the project needs:

- **postgres** (Prisma / Drizzle / Knex / TypeORM with `postgres`):
  ```yaml
  postgres:
    image: postgres:16
    environment:
      - POSTGRES_HOST_AUTH_METHOD=trust
      - POSTGRES_DB=app_dev
  ```
- **mysql** (TypeORM / Prisma with `mysql`):
  ```yaml
  mysql:
    image: mysql:8
    environment:
      - MYSQL_ALLOW_EMPTY_PASSWORD=yes
      - MYSQL_DATABASE=app_dev
  ```
- **mongodb** (Mongoose):
  ```yaml
  mongodb:
    image: mongo:7
  ```
- **redis** (BullMQ / IORedis / cache layer):
  ```yaml
  redis:
    image: redis:7-alpine
  ```

## Env vars

```
NODE_ENV=development
HOST=0.0.0.0
PORT=3000
DATABASE_URL=postgres://postgres@postgres:5432/app_dev    # adjust per project
REDIS_URL=redis://redis:6379
```

If the project has `.env.example`, copy it and override the host/port-specific vars to point at compose service names (`postgres` not `localhost`).

## After docker_compose up

```
exec("npm install")                  # or pnpm install / yarn install / bun install
exec("npm rebuild")                  # rebuilds native deps for Linux (sharp, bcrypt, sqlite3)
exec("npx prisma migrate dev")       # if Prisma
exec("npx prisma generate")          # if Prisma
exec("npx drizzle-kit push")         # if Drizzle
exec("npx typeorm migration:run")    # if TypeORM
```

For TypeScript projects with a build step:
```
exec("npm run build")                # if dev script needs compiled output
```

Most modern Node projects use `tsx watch` / `tsx watch src/server.ts` and don't need a separate build step in dev.

## Bun apps

If `bun.lockb` exists or `package.json` mentions `bun`, switch to:

```dockerfile
FROM oven/bun:1
WORKDIR /workspace
```

```yaml
command: bun run dev          # or: bun --hot src/server.ts
```

Bun handles TypeScript natively — no separate build step.

## Gotchas

- **Native binaries from macOS in node_modules** — `npm install` from the host put darwin-arm64 binaries in `node_modules`. Always run `npm install` (or `npm rebuild`) from inside the container after first `docker_compose up`. The native binaries (sharp, bcrypt, esbuild, swc) need Linux versions.
- **`localhost` in .env files** — `.env.local` / `.env.development` often has `DATABASE_URL=postgres://localhost/...` which won't reach the postgres compose service. Override in docker-compose.yml `environment:` or in a `.env` file the agent writes.
- **`tsx watch` vs `nodemon`** — `tsx` is the modern choice for TS projects, `nodemon` for plain JS. They both watch and restart but have different config files. Don't introduce one if the project uses the other.
- **Workspaces / monorepos.** If `package.json` has `workspaces` or there's a `turbo.json`, the project is a monorepo. The dev command might need to be filtered: `pnpm --filter web dev` or `turbo run dev --filter=web`. Read the README and the root `package.json` scripts.
- **Ports may be auto-allocated** if the framework reads `process.env.PORT` and you don't set it. Always set `PORT=3000` in env to keep it predictable.
- **NestJS uses `nest start --watch`** which compiles to `dist/` and runs from there. First run can take 30s+; be patient before declaring it dead.
