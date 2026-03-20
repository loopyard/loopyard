# Boom Looper — Multi-Player Claude Code Runner

A Phoenix LiveView app that lets a team share and interact with Claude Code agents in real-time through a chat interface.

**This is a multiplayer app.** Multiple people watch and interact with agents simultaneously from laptops, iPads, iPhones, etc. All UI state that matters must be server-driven (assigns, PubSub) — never rely on client-side state like `<details>` open/closed, JS toggles, or localStorage for anything that should be consistent across viewers. If you can't sync it, just show it.

## What it does

- **Projects** are git repos. Each project can have multiple **branches** (git worktrees).
- Each branch gets its own set of Docker containers (workspace, dev server, services) and agents.
- Left sidebar: agents and services for the current branch
- Right panel: chat interface with message bubbles, tool call cards, streaming responses
- Any connected browser can send messages to any agent — responses broadcast to all viewers
- URL-based routing: `/p/:project_id/b/:branch_id/chat/:id`
- Responsive: works on phones, tablets, and desktops
- Launch from terminal: `open "http://localhost:4000/launch/SECRET?path=$(pwd)"`

## Architecture

### Data model

```
Project (git repo)
  ├── Branch "main"        → workspace container + dev container + services + agents
  ├── Branch "feature-x"   → separate set of containers + agents
  └── .hive/workspace.json → shared config (Dockerfile, services, env vars)
```

### Supervisor tree

```
BoomLooper.Supervisor
  ├── Phoenix.PubSub
  ├── Registry (ChatAgentRegistry, ServiceManagerRegistry, BranchRegistry, BranchAgentRegistry)
  ├── BranchSupervisor (DynamicSupervisor)
  │   ├── Branch "main" (Supervisor, :one_for_all)
  │   │   ├── ServiceManager (manages Docker containers)
  │   │   └── AgentSupervisor (DynamicSupervisor)
  │   │       ├── ChatAgent "Setup"
  │   │       └── ChatAgent "dev-agent"
  │   └── Branch "feature-x" (Supervisor)
  │       ├── ServiceManager
  │       └── AgentSupervisor
  └── BoomLooperWeb.Endpoint
```

Stopping a branch = `Supervisor.stop` cascades → ServiceManager.terminate cleans up all Docker containers → agents die. No orphan containers.

### Container model

Each branch has:
- **Workspace container** — always running `sleep infinity`, agents exec here. Never crashes. The escape hatch.
- **Dev container** — runs from the workspace image with the dev command (e.g. `bin/dev`). Has its own `docker logs`.
- **Stock services** — postgres, redis, etc. in their own containers with their own images.

All containers share a Docker network. Agents exec into the workspace container for code changes. The dev server in the dev container picks up changes because both mount the same host directory.

Port allocation is dynamic (`-p 0:container_port`) — Docker picks host ports. Multiple branches run without port conflicts.

### Key files

- `lib/boom_looper/branch.ex` — Per-branch Supervisor (ServiceManager + AgentSupervisor)
- `lib/boom_looper/branch_supervisor.ex` — DynamicSupervisor for branch subtrees
- `lib/boom_looper/project_registry.ex` — Projects and branches registry (ETS)
- `lib/boom_looper/git.ex` — Git CLI wrapper (worktree add/remove/list)
- `lib/boom_looper/chat_agent.ex` — GenServer wrapping a Claude Code SDK session
- `lib/boom_looper/workspace/service_manager.ex` — Manages Docker containers per branch
- `lib/boom_looper/docker.ex` — Docker CLI wrapper
- `lib/boom_looper_web/live/chat_live.ex` — Branch-level chat UI
- `lib/boom_looper_web/live/project_list_live.ex` — Home page (projects)
- `lib/boom_looper_web/live/project_live.ex` — Project page (branches)
- `lib/boom_looper/tools/workspace.ex` — MCP tools: set_dockerfile, set_dev_command, add_service, rebuild, etc.
- `lib/boom_looper/tools/container.ex` — MCP tools: exec, logs, inspect, ports

### How agents work

Each agent is a GenServer that owns a `ClaudeCode` SDK session. The SDK spawns `claude` CLI as a subprocess. When a user sends a message, the agent streams the response via PubSub.

Agents exec into the workspace container (sleep infinity) for code changes, tests, installs. The dev server runs in a separate container. Agents reach it via Docker network hostname (e.g. `curl http://boom-looper-ws-XXXX-dev:3000/`).

### What is a service?

A **service** is something with a port that you connect to. It runs in its own Docker container.
- postgres on 5432, redis on 6379, the dev server on 3000
- Each gets its own container, its own `docker logs`, its own lifecycle

A service is NOT a CSS watcher, JS bundler, or background worker. Those run inside the dev command (e.g. `bin/dev` which uses foreman/overmind internally).

## Configuration (12-Factor)

All runtime config from environment variables. `.env` files loaded automatically in dev/test via `dotenvy`.

```bash
cp .env.example .env
```

| Variable | Required | Default | Description |
|---|---|---|---|
| `SECRET_KEY_BASE` | prod only | — | `mix phx.gen.secret` |
| `PHX_HOST` | prod only | `example.com` | Production hostname |
| `PORT` | no | `4000` | HTTP port |
| `BOOM_LOOPER_AUTH_PASSWORD` | no | — | Enable HTTP Basic Auth |
| `BOOM_LOOPER_AUTH_USERNAME` | no | *(any)* | Require specific username |

## Running

```bash
export MIX_HOME="$PWD/.mix_home"
export HEX_HOME="$PWD/.hex_home"

mix local.hex --force
mix deps.get
mix assets.setup
mix assets.build

mix phx.server
# http://localhost:4000
```

On startup, a launch command is printed to the terminal. Run it from any project directory to register the project and start working.

## Testing

**Test coverage is critical.** Every change must be backed by tests.

```bash
mix test                    # Run all tests
mix test --trace            # Verbose output
```

### Test philosophy

- Every new feature must have tests
- Every bug fix starts with a failing test
- Test behavior, not implementation
- Tests must be fast — no `Process.sleep` hacks
- LiveView tests cover user flows
- Plans require tests

### Test tags

- Default: all tests run with `mix test`
- `@tag :docker` — requires Docker daemon
- `@tag :worktree` — creates git worktrees

### Test helpers

Use `BoomLooper.TestHelpers.ensure_branch(path)` to start a branch subtree before starting agents in tests. Use `BoomLooper.TestHelpers.start_agent(opts)` instead of the old `ChatAgentSupervisor.start_agent`.

## Code style

### Composition over conditionals

Use functional composition — small, focused components and functions. Each component does one thing.

### One concept, one code path

Don't create parallel implementations for things that are really the same thing with different config.

### Tests skip external dependencies by default

`ChatAgent` does not create Docker containers on init — containers are managed by `ServiceManager` within the branch supervisor tree. Only tests tagged `@tag :docker` should actually create containers.

## Git workflow

- **Atomic commits.** Each commit is a self-contained, working change.
- Run `mix test` before committing. All tests must pass.
- Write descriptive commit messages that explain *why*, not just *what*.

## Stack

- Elixir 1.19 / OTP 28
- Phoenix 1.7 / LiveView 1.1
- Claude Code SDK (`claude_code` hex package) for structured agent communication
- Tailwind CSS (dark mode via `prefers-color-scheme`)
- Bandit (HTTP server)
- No database (all state in-memory — ETS for agent state, GenServers for lifecycle)
- Docker for container management

## Known issues / TODOs

- No persistence across server restarts — projects/agents reconstructed on launch
- Agent message history grows unbounded in memory
- Service logs flash briefly when containers restart
