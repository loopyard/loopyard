---
name: setup
description: Set up Boom Looper on a new machine
user_invocable: true
---

# Setup

Get Boom Looper running on a new machine.

## macOS

### 1. Check dependencies

```bash
which elixir && elixir --version
which docker || echo "Install Docker - see step 2"
which claude || echo "Install with: npm install -g @anthropic-ai/claude-code"
```

### 2. Docker runtime

Check if Docker is already running:

```bash
docker info >/dev/null 2>&1 && echo "Docker is running" || echo "Docker not running"
```

If Docker is running, skip to step 3. Otherwise, pick ONE of these options:

**Option A: Docker Desktop** (easiest)
Download from https://www.docker.com/products/docker-desktop/ and start it.

**Option B: OrbStack** (fast, nice GUI)
Download from https://orbstack.dev/ or `brew install orbstack`. Start it and it auto-configures Docker.

**Option C: Colima** (lightweight, CLI-only)
Use the `colima-setup` skill to configure with optimal resources, or manually:
```bash
brew install colima docker
colima start --cpu 4 --memory 8 --disk 100 --vm-type vz --vz-rosetta
```

Verify with `docker info`.

### 3. Clone and build

```bash
git clone https://github.com/boomlooper/boomlooper.git
cd boomlooper
export MIX_HOME="$PWD/.mix_home" HEX_HOME="$PWD/.hex_home"
mix local.hex --force && mix deps.get && mix assets.setup && mix assets.build
```

### 4. Start the server

```bash
export MIX_HOME="$PWD/.mix_home" HEX_HOME="$PWD/.hex_home"
mix phx.server
```

**Important:** Always set `MIX_HOME` and `HEX_HOME` before running mix commands. This uses a project-local Hex installation to avoid conflicts with your system Hex.

### 5. Development console (optional)

For IEx console access during development, use `Procfile.dev`:

```bash
overmind start -f Procfile.dev  # or use your preferred process manager
```

Then connect via remote shell:

```bash
iex --sname claude --remsh boom@$(hostname -s)
```

From IEx you have full access to inspect/control the system:

```elixir
BoomLooper.ProjectRegistry.list_projects()
BoomLooper.ChatAgent.list_agents()
:ets.tab2list(:project_registry)
```

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
```

Start the server (remember to set the env vars in each new terminal):

```bash
export MIX_HOME="$PWD/.mix_home" HEX_HOME="$PWD/.hex_home"
mix phx.server
```

For development with IEx console access, see "Development console" in the macOS section above.

## Troubleshooting

**"BEAM file was compiled for an old version"**: You forgot to set the environment variables. Run:
```bash
export MIX_HOME="$PWD/.mix_home" HEX_HOME="$PWD/.hex_home"
mix local.hex --force
```
Then try again.

**`mix phx.server` fails with "could not compile dependency"**: Run `mix deps.clean --all && mix deps.get` and try again.

**Docker not found**: Make sure your Docker runtime is installed and running. On macOS use Docker Desktop, OrbStack, or Colima. On Linux use docker.io. Verify with `docker info`.

**Claude CLI not found**: `npm install -g @anthropic-ai/claude-code`. Make sure Node.js is installed.

**Port 4000 in use**: Set a different port with `PORT=4001 mix phx.server`.

## ARM64 / Apple Silicon Service Images

When configuring services in workspace.json on Apple Silicon (M1/M2/M3/M4), prefer images with ARM64 builds. AMD64-only images will run under emulation (slower, sometimes buggy).

**Check if an image has ARM64:**
```bash
docker manifest inspect <image>:<tag> 2>&1 | grep -i "architecture"
```

Look for `arm64` or `aarch64`. If only `amd64` is available:

1. **Find an alternative image** - Many popular images have ARM64 builds from different publishers (e.g., `ghcr.io/baosystems/postgis` instead of `postgis/postgis`)

2. **Build from Dockerfile** - Most images publish their Dockerfile on GitHub. Clone and build locally for native ARM64:
   ```bash
   # Example: PostGIS doesn't have ARM64, but you can build it
   git clone https://github.com/postgis/docker-postgis
   cd docker-postgis/17-3.5
   docker build -t postgis:17-3.5-arm64 .
   ```
   Then reference your local image in workspace.json.

3. **Accept emulation** - If the service isn't performance-critical, AMD64 emulation works fine for dev. Just expect ~2-3x slower performance.

### Colima issues (macOS)

**Colima fails to start with socket error**: Clean up stale files and try again:
```bash
rm -rf ~/.colima/_lima/_networks/user-v2/
rm -rf ~/.colima/_lima/colima/
colima start ...
```

**"vz is not supported"**: You need macOS 13+ and Apple Silicon. Use `--vm-type qemu` instead.

**"rosetta is not available"**: Run `softwareupdate --install-rosetta` first.
