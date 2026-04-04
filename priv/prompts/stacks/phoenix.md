# Phoenix / Elixir

## Dockerfile

```dockerfile
FROM elixir:1.18
RUN apt-get update && apt-get install -y \
    build-essential git curl inotify-tools \
    && rm -rf /var/lib/apt/lists/*
ENV MIX_HOME=/workspace/.mix_home HEX_HOME=/workspace/.hex_home
WORKDIR /workspace
```

Check `mix.exs` for Elixir version. Add `nodejs npm` if project has JS assets. Add `libpq-dev` if using Ecto with postgres.

## Dev command

`mix phx.server` on port `4000`. Phoenix binds `0.0.0.0` by default in dev.

## Services

- **postgres:** `postgres:16` — pass `env: {"POSTGRES_HOST_AUTH_METHOD": "trust"}` in `add_service` (if mix.exs has `:postgrex`)

## Env vars

```
DATABASE_URL=postgres://postgres@postgres:5432/<app>_dev
MIX_ENV=dev
```

## After rebuild

```
exec: mix local.hex --force && mix local.rebar --force
exec: mix deps.get
exec: mix ecto.create
exec: mix ecto.migrate
exec: mix assets.setup    # if assets pipeline exists
```

## Gotchas

- Set `MIX_HOME` and `HEX_HOME` inside `/workspace` so they persist across rebuilds
- If compilation fails with stale artifacts: `rm -rf _build deps && mix deps.get`
- `inotify-tools` needed for Phoenix live reload
