FROM elixir:1.18

# Install build deps and Node.js (needed for esbuild/tailwind)
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    curl \
    inotify-tools \
    && rm -rf /var/lib/apt/lists/*

# Set mix/hex homes inside workspace for caching
ENV MIX_HOME=/workspace/.mix_home
ENV HEX_HOME=/workspace/.hex_home

WORKDIR /workspace
