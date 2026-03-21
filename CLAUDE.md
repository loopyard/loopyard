# Boom Looper — Multi-Player Claude Code Runner

A Phoenix LiveView app that lets a team share and interact with Claude Code agents in real-time through a chat interface. Agents run code inside Docker containers.

**Multiplayer by design.** This means two things:
1. **Multiple people** can watch and interact with agents simultaneously from laptops, iPads, iPhones.
2. **One person, multiple windows** — tear off agent chats, service consoles, build logs, and message views into separate tabs/windows spread across monitors. Every view has its own URL and stays in sync via PubSub.

All UI state that matters is server-driven (assigns, PubSub). Never rely on client-side state for anything that should be consistent across viewers or windows.

## What it does

- **Projects** are git repos. Each project can have multiple **branches** (git worktrees).
- Each branch gets isolated Docker containers (workspace, dev server, databases) and its own agents.
- Chat interface: message bubbles, tool calls, streaming responses, inline build logs.
- Multiplayer: any connected browser can send messages to any agent — responses broadcast to all viewers.
- Every message is a resource with its own URL — tearable into a new tab, live-updating for streams.
- Interactive terminal console for any service container (xterm.js + WebSocket).
- Launch from terminal: `open "http://localhost:4000/launch/SECRET?path=$(pwd)"`

## System tools

All under `/system/`. Plain text responses for easy scripting.

```bash
# Dump system state — agents, containers, branches, event log
curl localhost:4000/system/debug

# Nuclear reset — kill all branches, agents, containers. Web stays up.
curl -X POST localhost:4000/system/reset

# Kill only Docker containers, keep agent state
curl -X POST localhost:4000/system/reset/containers
```

**Debug output** includes: branches (with supervisor status), agents (with CLI session alive check), Docker containers, and the last 100 event log entries. Paste the output into a conversation for diagnosis.

**Reset** cascades through the supervisor tree: stops all branches → ServiceManager.terminate kills containers → agents die → ETS cleared. The web layer stays up. Go to `/` and start fresh.

The `BoomLooper.EventLog` captures lifecycle events: agent starts/stops, CLI session crashes/restarts, stream errors, ServiceManager shutdowns. All events are timestamped with source labels.

## Architecture

### Two layers (views vs infrastructure)

The app is split into two independent layers that can restart without affecting each other:

1. **Infrastructure layer** — StateKeeper (ETS table owner), PubSub, Registries, BranchSupervisor, ServiceManagers, ChatAgents, ContainerMonitor, Terminal. Runs containers, manages agent lifecycles, holds all state. Survives web hot reloads.

2. **Web layer** — LiveViews, Controllers, Channels, Endpoint. Reads state from infrastructure and renders UI. Can restart freely without killing agents or containers.

### Supervisor tree

```
BoomLooper.Supervisor (:one_for_one)
  ├── StateKeeper (owns ETS tables — starts first, lives longest)
  ├── Phoenix.PubSub
  ├── Registry × 5 (ChatAgent, ServiceManager, Branch, BranchAgent, Terminal)
  ├── DynamicSupervisor (TerminalSupervisor)
  ├── BranchSupervisor (DynamicSupervisor)
  │   └── Branch (Supervisor, :one_for_all)
  │       ├── ServiceManager (manages Docker containers)
  │       ├── AgentSupervisor (DynamicSupervisor)
  │       │   └── ChatAgent × N
  │       └── ContainerMonitor (polls Docker health every 5s)
  └── BoomLooperWeb.Endpoint
```

Stopping a branch cascades: ServiceManager.terminate cleans up all Docker containers, agents die with their supervisor. `ctrl+c` cascades through the entire tree — no orphan containers.

### Container model

Each branch has:
- **Workspace container** — `sleep infinity`, agents exec here. Never crashes. The escape hatch for rebuilding, debugging, fixing broken services.
- **Dev container** — runs from workspace image with the dev command (e.g. `bin/dev`). Separate container with its own `docker logs`.
- **Stock services** — postgres, redis, etc. Own containers, own images. Data volumes auto-mounted from image VOLUME declarations.

All containers share a Docker network. Agents exec into the workspace container. The dev server picks up file changes because both containers mount the same host directory.

**Sticky ports**: Docker picks a random host port on first start. ServiceManager remembers the assignment and reuses it on restart — URLs don't change when containers restart.

### Data model

```
Project (git repo)
  ├── .hive/workspace.json  → shared config (Dockerfile, services, env vars, dev command)
  ├── Branch "main"         → workspace + dev + services + agents
  └── Branch "feature-x"    → separate isolated set of everything
```

Config lives at the project level. All branches inherit it. Each branch gets its own containers, volumes, and agents.

### How agents work

Each `ChatAgent` is a GenServer owning a `ClaudeCode` SDK session (claude CLI subprocess). When a user sends a message, the agent streams the response via PubSub. The LiveView subscribes and renders updates in real-time.

**CLI session health**: the agent checks if the CLI session is alive before every message send. If dead, it auto-restarts silently — the user sees "Session lost — reconnecting..." in the chat, not a cryptic error. If restart fails, the error is shown in the chat AND logged to EventLog.

**CLI session crashes during tool execution**: the streaming Task catches exits and reports them. The agent goes idle (no auto-replay — that causes loops). The user can send another message to continue.

### What is a service?

A **service** is something with a port that you connect to. It runs in its own Docker container.
- postgres on 5432, redis on 6379, the dev server on 3000
- Each gets its own container, its own `docker logs`, its own lifecycle

A service is NOT a CSS watcher, JS bundler, or background worker. Those run inside the dev command (`bin/dev` uses foreman/overmind internally). If it doesn't have a port, it belongs inside the dev command.

### Service console

Each service container has an interactive terminal (xterm.js) at `/p/:project_id/b/:branch_id/service/:name/console`. The Terminal GenServer wraps `docker exec -it` via an Erlang Port. Multiplayer — all viewers share one session. 50KB output buffer for late joiners.

### Messages as resources

Every chat message has a unique ID and its own URL. This is a first-class feature for collaboration.

- **Live page** (`/msg/:msg_id?token=...`) — LiveView. Streaming messages update in real-time. Multiplayer.
- **Raw text** (`/msg/:msg_id/raw?token=...`) — plain text for copying.

Use cases: tailing (tear off streaming exec into own window), sharing (link to a specific error), multi-monitor (spread outputs across windows).

Messages use unique IDs (not array indices) so URLs are stable. IDs assigned by `append_message`, stored in ETS. Streaming messages updated in-place via `ChatAgent.update_message/3`. All writes go through ChatAgent — never direct ETS writes. One source of truth.

Signed with Phoenix.Token (24-hour TTL).

**Architecture principle**: Each message is potentially its own app. Today we have simple text messages and streaming output viewers. In the future, messages could contain interactive diagrams, forms, question prompts, or any visualization. The MessageLive page is the container for these apps. The chat feed shows a compact inline version. The URL opens the full version. Design message types to be composable — extract interfaces that work both inline and full-page.

**Link rules**: Every link must be a real `<a href>` with `target="_blank" rel="noopener"`. No JS hacks. Cmd+Click must work. LiveView must not intercept these links. If a message doesn't have an ID yet, don't render the link.

## Key files

| File | Purpose |
|------|---------|
| `lib/boom_looper/state_keeper.ex` | Owns ETS tables, survives hot reloads |
| `lib/boom_looper/branch.ex` | Per-branch Supervisor (ServiceManager + AgentSupervisor + ContainerMonitor) |
| `lib/boom_looper/branch_supervisor.ex` | DynamicSupervisor for branch subtrees |
| `lib/boom_looper/chat_agent.ex` | GenServer wrapping Claude Code SDK session |
| `lib/boom_looper/workspace/service_manager.ex` | Manages Docker containers, sticky ports, volumes |
| `lib/boom_looper/docker.ex` | Docker CLI wrapper (exec, build, ports, volumes, state) |
| `lib/boom_looper/terminal.ex` | GenServer for interactive terminal sessions |
| `lib/boom_looper/container_monitor.ex` | Polls Docker health, broadcasts status changes |
| `lib/boom_looper/event_log.ex` | Append-only event log for debugging |
| `lib/boom_looper/project_registry.ex` | Projects + branches registry (ETS) |
| `lib/boom_looper/git.ex` | Git CLI wrapper (worktree add/remove/list) |
| `lib/boom_looper/tools/workspace.ex` | MCP tools: set_dockerfile, set_dev_command, add_service, rebuild |
| `lib/boom_looper/tools/container.ex` | MCP tools: exec, logs, inspect, ports |
| `lib/boom_looper_web/live/chat_live.ex` | Branch-level chat UI (agents + services + chat panel) |
| `lib/boom_looper_web/live/message_live.ex` | Single message view (live, multiplayer) |
| `lib/boom_looper_web/live/project_list_live.ex` | Home page (projects list) |
| `lib/boom_looper_web/live/project_live.ex` | Project page (branches with start/stop) |
| `lib/boom_looper_web/controllers/debug_controller.ex` | GET /debug — system state dump |
| `lib/boom_looper_web/controllers/launch_controller.ex` | GET /launch/:secret — CLI onramp |
| `lib/boom_looper_web/channels/terminal_channel.ex` | WebSocket for terminal I/O |

## Configuration

All runtime config from environment variables. `.env` files loaded automatically in dev/test via `dotenvy`.

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
```

On startup, a launch command is printed. Run it from any project directory.

## Testing

```bash
mix test                    # Run all tests
mix test --trace            # Verbose output
```

### Test helpers

- `BoomLooper.TestHelpers.ensure_branch(path)` — start a branch subtree before starting agents
- `BoomLooper.TestHelpers.start_agent(opts)` — start an agent under the correct branch

### Test tags

- `@tag :docker` — requires Docker daemon
- `@tag :worktree` — creates git worktrees

## Code rules

These rules exist because we learned them the hard way. Each one prevented a real bug.

### No side effects in LiveView mount or handle_params

Mount runs on every navigation, reconnect, and hot reload. It must be **read-only**. Never start services, create containers, or modify external state on mount. This rule exists because `maybe_start_services` in mount was killing and recreating containers on every page load.

### Operations must be idempotent

Check if running before starting. Never `docker rm -f` then `docker run` unconditionally.

### Don't swallow errors

Always check return values from Docker commands. Log failures. Silent failures cause orphaned containers and state drift that's impossible to debug.

### Everything through Dockerfiles, never runtime scripts

Never install software via `docker exec apt-get`. It doesn't persist — container restarts, it's gone, agent loops trying to reinstall. Use the right image or write a Dockerfile.

### Use data attributes for JS state

Pass state to JS hooks via `data-*` attributes. Use modes (`data-copy="fetch"`) over flags. Never sniff URL paths in JavaScript.

### GenServer state must reflect Docker reality

Don't cache container state as booleans. Query Docker directly when reporting status. Cached state goes stale when Docker kills containers independently.

### Views observe, infrastructure acts

Views read state from ETS and GenServers. They never create or modify infrastructure state. Infrastructure modules never depend on web modules. This separation means hot-reloading a LiveView doesn't affect running agents or containers.

### Sticky ports

Services keep the same host port across container restarts within a server session. The ServiceManager remembers port assignments and reuses them. URLs don't change when the agent restarts a service.

### Auto-restart dead CLI sessions

ChatAgent checks `session_alive?` before every message send. If dead, it restarts silently and shows the recovery in the chat. If restart fails, it shows the error and goes idle — no auto-replay (that causes crash loops).

## Stack

- Elixir 1.19 / OTP 28
- Phoenix 1.7 / LiveView 1.1
- Claude Code SDK (`claude_code` hex package)
- Tailwind CSS (dark mode via `prefers-color-scheme`)
- xterm.js (interactive terminal)
- Bandit (HTTP server)
- Docker (container management)
- No database (ETS for state, GenServers for lifecycle)

## Known issues

- No persistence across server restarts (projects/agents lost, ports change)
- Agent message history grows unbounded in memory (future: SQLite per workspace)
- Secrets tests fail in sandbox (filesystem permission issue, pre-existing)
