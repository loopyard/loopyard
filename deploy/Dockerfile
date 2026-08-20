# Loopyard server image — the app plus its own Docker daemon.
#
# Loopyard is a Docker control plane: it creates volumes, builds images, and
# runs compose clusters. On a host where we can mount /var/run/docker.sock
# those containers are siblings. On Fly there is no socket to mount (a Machine
# is a Firecracker VM), so this image carries its own dockerd and the workspace
# containers are nested inside it — Docker-in-Docker.
#
# Requires: --privileged (dockerd needs to mount overlayfs, create netns, and
# program iptables). Port publishing is not optional here — PortRegistry,
# probe_http, and app_url are all built on Docker publishing to host ports.
#
#   docker build -f deploy/Dockerfile -t loopyard:server .

# ---------------------------------------------------------------- builder ---
FROM elixir:1.19-otp-28 AS builder

ENV MIX_ENV=prod \
    LANG=C.UTF-8

RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends git build-essential nodejs npm \
 && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /src

# Deps first, so a code change doesn't re-fetch the world. packages/ holds the
# path deps (:aural, :brand) and must land before deps.get can resolve them.
COPY mix.exs mix.lock ./
COPY packages packages
RUN mix deps.get --only prod && mix deps.compile

COPY config config
COPY assets assets
COPY priv priv
COPY lib lib

# app.css imports @xterm/xterm/css/xterm.css, so the JS deps must exist before
# tailwind runs. node_modules is not in git — build it from the tracked lock.
RUN npm --prefix assets ci

# assets.setup downloads the standalone tailwind/esbuild binaries.
RUN mix assets.setup && mix assets.deploy
RUN mix compile && mix release loopyard

# ---------------------------------------------------------------- runtime ---
FROM debian:trixie-slim AS runtime

ENV LANG=C.UTF-8 \
    PHX_SERVER=1 \
    LOOPYARD_HOME=/data/loopyard \
    DOCKER_DATA_ROOT=/data/docker

RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg git iptables openssl procps libncurses6 \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian trixie stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update -qq \
 && apt-get install -y --no-install-recommends \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

# The release bundles ERTS built against the builder image, so the runtime base
# MUST be the same Debian release (both trixie) — otherwise beam.smp fails to
# start on a glibc version mismatch.
COPY --from=builder /src/_build/prod/rel/loopyard /app
COPY deploy/entrypoint.sh deploy/dind-probe.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/dind-probe.sh

# /data holds BOTH the inner daemon's data-root (where named volumes — and so
# all workspace code — actually live) and LOOPYARD_HOME. Mount a volume here or
# a deploy destroys every workspace.
VOLUME ["/data"]

EXPOSE 4000 4030

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
