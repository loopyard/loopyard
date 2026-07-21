# The Loopyard work-container base image — the workstation every agent is
# stamped from (see Loopyard.Workspace.WorkContainer). It is also the harness
# host: the REAL Claude/Codex harness runs *inside* this container via ACP
# (`docker exec -i <work> claude-code-acp` / `codex`) against the mounted code
# volume. The box hosts a real harness; it does not reimplement one. New
# harnesses plug in by adding their adapter here; nothing else changes.
#
# Debian (glibc), not Alpine (musl): Ruby gem native extensions and Erlang NIFs
# — and precompiled CLIs (fly, codex) — expect glibc; musl bites too often for a
# dev box.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Core tools + build deps. The compiler/headers are here so mise can compile
# Erlang/Elixir and native Ruby gems on demand. Ruby is a sane present-on-boot
# default; mise handles current Elixir/Erlang + per-project version overrides.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-client bash rsync gnupg \
      build-essential autoconf m4 \
      libssl-dev libncurses-dev libyaml-dev zlib1g-dev \
      ruby-full \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI (`gh`) — official apt repo (Debian's own is stale/absent).
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Node (current LTS via NodeSource; Debian's is old) — the harness CLIs need it.
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Claude Code (`claude`) and Codex (`codex`) — the harnesses + their `…login`
# flows — plus the ACP adapter that runs the real harness in-box over stdio.
# acp pinned for reproducibility; bump deliberately.
RUN npm install -g \
      @anthropic-ai/claude-code \
      @openai/codex \
      @zed-industries/claude-code-acp@0.16.2

# Fly CLI (`fly`) — installed to a SYSTEM path (/usr/local), NOT $HOME: the
# $HOME volume would shadow anything the image placed under it, so system tools
# live outside $HOME. `fly auth login` writes its creds to ~/.fly at runtime.
RUN curl -L https://fly.io/install.sh | FLYCTL_INSTALL=/usr/local sh

# mise — polyglot version manager (Elixir/Erlang/Ruby/Node/…). The BINARY lives
# in a system path; the versions it installs go to ~/.local/share/mise on the
# $HOME volume → LIVE and per-project. It reads the .tool-versions /
# .ruby-version / .nvmrc files projects already ship. Primary win: current +
# per-project Elixir/Erlang, which Debian's apt can't give you.
RUN curl https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh

# Browser shim — the box is headless, so a CLI that tries to open a URL
# (`gh repo view --web`, a printed login link) would otherwise hit
# "xdg-open: not found". Instead we print the URL on its own line; the console's
# web-links addon makes it tappable. CLIs honor $BROWSER, and many call xdg-open
# directly, so we wire both to the shim.
COPY loopyard-open /usr/local/bin/loopyard-open
RUN chmod +x /usr/local/bin/loopyard-open \
    && ln -sf /usr/local/bin/loopyard-open /usr/local/bin/xdg-open
ENV BROWSER=/usr/local/bin/loopyard-open

WORKDIR /workspace

CMD ["sleep", "infinity"]
