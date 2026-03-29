FROM elixir:1.18-otp-27

# Install build deps, Node.js (for esbuild/tailwind), and inotify-tools (for live reload)
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    curl \
    inotify-tools \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

# Install Claude CLI globally (required by claude_code dependency)
RUN npm install -g @anthropic-ai/claude-code

# Set mix/hex homes inside workspace for caching
ENV MIX_HOME=/workspace/.mix_home
ENV HEX_HOME=/workspace/.hex_home

WORKDIR /workspace
