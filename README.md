# Boom Looper

Multiplayer Claude Code runner. A Phoenix LiveView app that lets a team share and interact with Claude Code agents in real-time through a chat interface. Agents run code inside Docker containers.

## Prerequisites

- **Elixir** >= 1.17 with **OTP** >= 27
- **Docker** (with Compose v2)
- **Claude Code CLI** (`claude`)

### macOS (Homebrew)

```bash
# Elixir & Erlang
brew install elixir

# Docker
brew install --cask docker
# Start Docker Desktop, then verify:
docker compose version

# Claude Code CLI
npm install -g @anthropic-ai/claude-code
```

### Linux (apt)

```bash
# Erlang & Elixir (via Erlang Solutions repo)
sudo apt-get install -y software-properties-common
wget https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
sudo dpkg -i erlang-solutions_2.0_all.deb
sudo apt-get update
sudo apt-get install -y esl-erlang elixir

# Docker (official repo)
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker $USER
# Log out and back in for group change to take effect

# Claude Code CLI
npm install -g @anthropic-ai/claude-code
```

## Quick start

```bash
git clone https://github.com/bradgessler/hive.git
cd hive

export MIX_HOME="$PWD/.mix_home" HEX_HOME="$PWD/.hex_home"
mix local.hex --force && mix deps.get && mix assets.setup && mix assets.build
mix phx.server
```

Then launch from any project directory:

```bash
open "http://localhost:4000/launch/SECRET?path=$(pwd)"
```

The actual secret is printed to your terminal when the server starts.

## How it works

1. **Launch a project** — point Boom Looper at a git repo
2. **Setup agent** auto-detects the stack and writes a Dockerfile, services, and dev command
3. **Docker Compose** builds and runs everything — workspace container, dev server, databases
4. **Agents exec into the workspace container** and use Claude Code to write/run code
5. **Multiple people** can watch and interact with agents simultaneously in real-time

## System tools

```bash
curl localhost:4000/system/debug                     # Dump system state
curl -X POST localhost:4000/system/reset             # Nuclear reset (kills containers)
curl -X POST localhost:4000/system/reset/containers  # Kill containers only
```

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for system design, supervisor tree, container model, and data flow.

See [docs/TESTING.md](docs/TESTING.md) for test strategy, contracts, and helpers.
