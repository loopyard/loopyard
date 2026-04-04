# Next.js / Node

## Dockerfile

```dockerfile
FROM node:22-slim
RUN apt-get update && apt-get install -y git curl && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
```

Check `.nvmrc` or `.node-version` — if it specifies a different major version, adjust the FROM tag.

## Dev command

`npm run dev` or `yarn dev`. Port is usually `3000`.

## Services

- **postgres:** `postgres:16` — pass `env: {"POSTGRES_HOST_AUTH_METHOD": "trust"}` in `add_service` (if using Prisma/Drizzle with postgres)

## Env vars

```
HOST=0.0.0.0
DATABASE_URL=postgres://postgres@postgres:5432/<app>_dev
NODE_ENV=development
```

## After rebuild

```
exec: npm install
exec: npx prisma migrate dev    # if using Prisma
exec: npx prisma generate       # if using Prisma
```

## Gotchas

- `npm install` inside the container gets Linux-native binaries (replaces macOS ones from volume)
- If `sharp` or `esbuild` crashes with "Exec format error": `npm rebuild`
- Next.js reads `.env.local` for env vars — database URLs there may point to `localhost` instead of the Docker service name. Override with `set_env_vars`.
