---
name: setup
description: Set up Boom Looper on a new machine
user_invocable: true
---

# Setup

Get Boom Looper running on a new machine.

## macOS

Run the setup script:

```bash
git clone https://github.com/boomlooper/boomlooper.git
cd boomlooper
bin/setup
```

This installs everything via Homebrew (Elixir, Node, Docker Desktop), installs Claude Code CLI, fetches Elixir deps, and builds assets.

Then start the server:

```bash
mix phx.server
```

If Docker Desktop isn't running, open it first and wait for it to start.

## Linux

Install dependencies manually:

```bash
# Erlang & Elixir
sudo apt-get install -y software-properties-common
wget https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
sudo dpkg -i erlang-solutions_2.0_all.deb
sudo apt-get update
sudo apt-get install -y esl-erlang elixir

# Docker
sudo apt-get install -y docker.io docker-compose-plugin
sudo usermod -aG docker $USER
# Log out and back in for group change

# Node.js + Claude Code CLI
sudo apt-get install -y nodejs npm
npm install -g @anthropic-ai/claude-code
```

Then clone and build:

```bash
git clone https://github.com/boomlooper/boomlooper.git
cd boomlooper
export MIX_HOME="$PWD/.mix_home" HEX_HOME="$PWD/.hex_home"
mix local.hex --force && mix deps.get && mix assets.setup && mix assets.build
mix phx.server
```

## Troubleshooting

**`mix phx.server` fails with "could not compile dependency"**: Run `mix deps.clean --all && mix deps.get` and try again.

**Docker not found**: Make sure Docker Desktop (macOS) or docker.io (Linux) is installed and running. Verify with `docker info`.

**Claude CLI not found**: `npm install -g @anthropic-ai/claude-code`. Make sure Node.js is installed.

**Port 4000 in use**: Set a different port with `PORT=4001 mix phx.server`.
