---
name: setup
description: Set up Loopyard on a new machine
user_invocable: true
---

# Setup

Get Loopyard running on a new machine.

## Quick start

### 1. Prerequisites

You need a Docker runtime. Pick ONE:

- **Colima** (recommended): `brew install colima docker && colima start --cpu 4 --memory 8 --disk 100 --vm-type vz --vz-rosetta`
- **OrbStack**: `brew install orbstack` and start it
- **Docker Desktop**: Download from docker.com

Verify with `docker info`.

### 2. Setup + run

```bash
git clone https://github.com/loopyard/loopyard.git
cd loopyard
mix loopyard.setup    # installs everything, fixes Docker config
mix loopyard.server   # starts the server
```

`mix loopyard.setup` handles Brewfile deps, Docker credential store fixes, Hex/Rebar, Mix deps, and assets. Safe to re-run.

### 3. Remote access

Once the server is running, jack in from another terminal:

```bash
mix loopyard.rpc "Loopyard.ProjectRegistry.list_projects()"
```

Any valid Elixir expression works.

## Linux

Install Erlang, Elixir, Docker, and Node.js via your package manager, then:

```bash
git clone https://github.com/loopyard/loopyard.git
cd loopyard
mix loopyard.setup
mix loopyard.server
```

`mix loopyard.setup` skips Brewfile on Linux (no brew) but handles everything else.

## Troubleshooting

**Compilation errors after update**: Run `mix loopyard.setup` to re-fetch deps and rebuild assets.

**Docker not found**: Make sure your Docker runtime is installed and running. Verify with `docker info`.

**Docker pulls hang**: Run `mix loopyard.setup` — it detects and fixes the Docker Desktop credential store issue automatically.

**Port 4000 in use**: `PORT=4001 mix loopyard.server`.

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
