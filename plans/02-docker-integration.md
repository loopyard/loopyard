---
title: Docker Integration
status: planned
depends_on: []
---

# Docker Integration

Run each agent's Claude Code session inside a Docker container. The container is the security sandbox — no permission prompts, no host filesystem access.

## Self-Improving Dockerfiles

Dockerfiles are annoying. The agent should handle its own environment setup. The flow:

1. Agent starts with a minimal base Dockerfile (ubuntu + claude CLI + git)
2. Agent tries to do something (e.g. `npm install`) and it fails because node isn't installed
3. Agent edits its Dockerfile to add `RUN apt-get install -y nodejs npm`
4. Agent calls `Container.rebuild()` which rebuilds the image and restarts the container
5. Agent retries the original command — now it works

The Dockerfile lives in the agent's workspace (a volume). Each agent has its own. Over time, agents build up customized environments.

```
workspace/
  Dockerfile          ← agent edits this
  project/            ← the actual code
```

### Rebuild tool

```elixir
tool :rebuild, "Rebuild the container from the agent's Dockerfile" do
  field :agent_id, :string, required: true
  # Stops container, rebuilds image from workspace/Dockerfile, starts new container
  # Preserves the workspace volume so files survive rebuild
end
```

## Two Types of Containers

### Dev Environment
Where the agent writes code, runs git, installs deps. Always running.
- Workspace volume mounted at `/workspace` (persists across rebuilds)
- Claude CLI runs here
- Has the Dockerfile the agent can edit

### Preview Server
Where the web app runs. May be the same container or separate.
- Port mapped to host (so browser tool can reach it)
- Logs streamed to Hive for the UI panel
- Agent starts/stops it via tool

**Simplest approach**: same container for both. Dev env IS the preview server. Agent runs `npm run dev` inside it. One less thing to manage. Separate later if needed.

## Ports

Each container gets a port range allocated by Hive:
- Container N gets host port `10000 + N` mapped to container port `3000`
- Hive tracks the mapping: `agent_id → host_port`
- Browser tool uses the host port to connect
- UI shows the port so humans can visit too

Alternative: Docker random port (`-P`), then query with `docker port`. Simpler but less predictable.

## Volumes

- **Workspace volume** (`hive-workspace-{agent_id}`): mounted at `/workspace`. Survives container rebuilds. Contains Dockerfile, project files, agent's git repo.
- **Cache volume** (`hive-cache-{agent_id}`): mounted at `/root/.cache`. npm/pip/apt caches survive rebuilds so installs are fast.

Volumes destroyed when agent is permanently deleted (not on stop/rebuild).

## Docker lifecycle

```
Agent created
  → Create workspace volume
  → Copy base Dockerfile into volume
  → Build image from Dockerfile
  → Run container with volume mounts + port mapping
  → Start claude CLI inside container

Agent rebuilds (after Dockerfile edit)
  → Stop container
  → Rebuild image from workspace/Dockerfile
  → Run new container (same volumes, same port)
  → Restart claude CLI

Agent stopped
  → Stop container
  → Keep volumes (for resume)

Agent deleted
  → Stop container
  → Remove container
  → Remove volumes
```

## Base Dockerfile

```dockerfile
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y \
    curl git build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install claude CLI
RUN curl -fsSL https://cli.anthropic.com/install.sh | sh

WORKDIR /workspace

CMD ["sleep", "infinity"]
```

Agent will add to this as needed. The `sleep infinity` keeps the container alive; claude is started via `docker exec`.

## How the SDK talks to claude in Docker

The ClaudeCode SDK spawns a subprocess. Instead of spawning `claude` locally, we configure it to spawn `docker exec -i {container} claude ...`. The `-i` flag keeps stdin open for the NDJSON stream.

Need to check: does the SDK's `:cli_path` or command option support this? If not, we wrap it in a shell script.

## Open questions

- Does the SDK support custom CLI commands (e.g. `docker exec -i container claude`)?
- Should we use Docker Compose for multi-container setups later?
- How to handle ANTHROPIC_API_KEY inside the container? (env var pass-through)
- Rate limiting container rebuilds (agent shouldn't rebuild 100x/minute)

## Acceptance criteria

- [ ] Base Dockerfile works with claude CLI
- [ ] Agent spawns inside a Docker container
- [ ] Agent can edit its Dockerfile and rebuild
- [ ] Workspace volume persists across rebuilds
- [ ] Port mapping works — browser can reach web server
- [ ] Container destroyed on agent delete, volumes cleaned up
- [ ] Cache volume speeds up repeated installs
- [ ] Tests for full lifecycle (with Docker daemon)
