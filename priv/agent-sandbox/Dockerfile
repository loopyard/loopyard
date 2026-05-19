# Loopyard agent sandbox image.
#
# Every agent gets its own container built from this image, named
# `loopyard-<workspace_id>-agent-<agent_id>`, mounted on the
# workspace's code volume at /workspace, run with `--network none`.
# This is the agent's runtime — all tool calls (`exec`, `grep`,
# `read_file`, etc.) target this container.
#
# Keep this minimal. Language toolchains (`mix`, `npm`, `cargo`)
# deliberately do NOT live here — agents reach the user's compose
# services via `docker_compose exec <service> <cmd>` when they need
# language work. See plans/agent-shell-container.md.
FROM alpine:3.19

RUN apk add --no-cache \
    bash \
    ca-certificates \
    coreutils \
    curl \
    findutils \
    git \
    github-cli \
    jq \
    openssh-client \
    ripgrep \
    rsync

WORKDIR /workspace

CMD ["sleep", "infinity"]
