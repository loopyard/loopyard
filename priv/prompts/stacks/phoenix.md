# Phoenix Stack Guide

## Base image

Use `elixir:1.18`. Check `mix.exs` for the elixir version requirement.

## Dockerfile pattern

```dockerfile
FROM elixir:1.18

RUN apt-get update && apt-get install -y \
    build-essential git curl inotify-tools \
    && rm -rf /var/lib/apt/lists/*

ENV MIX_HOME=/workspace/.mix_home
ENV HEX_HOME=/workspace/.hex_home

WORKDIR /workspace
```

Check `mix.exs` for extras:
- Ecto with postgres → add `libpq-dev` (for compiling postgrex)
- Node.js assets → add `nodejs npm`

## Dev command

Usually `mix phx.server` or a custom `mix` task. Default port is 4000.

`set_dev_command` with `command: "mix phx.server"`, `ports: ["4000"]`.

## Services

- **PostgreSQL:** `postgres:16` with `POSTGRES_HOST_AUTH_METHOD=trust`
- **Env vars:** `DATABASE_URL=postgres://postgres@postgres:5432/<app>_dev`, `MIX_ENV=dev`, `PHX_HOST=localhost`

## After rebuild

```
exec: mix local.hex --force && mix local.rebar --force
exec: mix deps.get
exec: mix ecto.create
exec: mix ecto.migrate
exec: mix assets.setup    # if assets pipeline exists
```

## Common gotchas

- **Tailwind polling:** Set `TAILWINDCSS_POLL=true` env var.
- **Mix/Hex homes:** Set `MIX_HOME` and `HEX_HOME` to paths inside `/workspace` so they persist across rebuilds.
- **inotify-tools:** Install in Dockerfile for live reload (even though polling is needed for bind mounts, Phoenix still uses inotify for some things).
