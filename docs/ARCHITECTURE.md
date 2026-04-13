# Architecture

## Docker-first principle

Everything inside a dev environment is Docker: compose clusters, named volumes, container images. There is no host filesystem access from agents or running containers.

**Source adapters are the ingress layer.** `Source.Local` syncs host files into the Docker volume via Mutagen. `Source.GitHub` (future) clones via API into the volume. But once code is in the volume, everything is Docker. Source adapters don't participate in the dev environment — they just get code in.

**Agents and humans see the same state through the same interfaces.** Agents use MCP tools (`exec`, `read_file`, `docker_compose`) that go through `Docker.exec_in` and `VolumeIO`. Humans see the same data in the UI (service logs, file browser, terminal console). The terminal console uses the same `docker exec` path as agent tools.

**Tool output truncation.** Agent tool output is truncated (via `Helpers.truncate_for_agent`, ~80 lines) to save context tokens. Humans see the full output streamed to the chat UI and log panels. This means agents get bounded summaries while humans can scroll through everything.

**The boundary.** `Source.Local` touches the host (Mutagen sync, git worktrees). Everything else is Docker. Agents never read or write the host filesystem. All file operations go through `VolumeIO` (which uses `docker run` with the volume mounted). All command execution goes through `Docker.exec_in`.

## Two layers (views vs infrastructure)

The app is split into two independent layers that can restart without affecting each other:

1. **Infrastructure layer** — StateKeeper (ETS table owner), PubSub, Registries, Docker.Observer, WorkspaceSupervisor, ServiceManagers, ChatAgents, ContainerMonitor, Terminal. Runs containers, manages agent lifecycles, holds all state. Survives web hot reloads.

2. **Web layer** — LiveViews, Controllers, Channels, Endpoint. Reads state from infrastructure and renders UI. Can restart freely without killing agents or containers.

## Supervisor tree

```
BoomLooper.Supervisor (:one_for_one)
  ├── LogBuffer
  ├── IExSession
  ├── StateKeeper (sole ETS table owner — starts first, lives longest)
  ├── Phoenix.PubSub
  ├── Registry × 6 (ChatAgent, ServiceManager, Workspace, WorkspaceAgent, SyncMonitor, Terminal)
  ├── DynamicSupervisor (TerminalSupervisor)
  ├── Task.Supervisor (TaskSupervisor — all fire-and-forget Tasks go here)
  ├── WorkspaceSupervisor (DynamicSupervisor)
  │   └── WorkspaceGroup (Supervisor, :one_for_all)
  │       ├── ServiceManager (manages Docker Compose services)
  │       ├── AgentSupervisor (DynamicSupervisor)
  │       │   └── ChatAgent × N
  │       └── ContainerMonitor (polls Docker health every 5s)
  ├── SSHServer
  ├── Docker.Observer (event-driven container/volume cache)
  └── BoomLooperWeb.Endpoint
```

**Key properties:**
- StateKeeper starts first, creates ALL named ETS tables, and lives longest. No other module creates ETS tables.
- Docker.Observer starts before Endpoint so the ETS cache is warm for the first LiveView mount.
- ServiceManager.terminate does NOT call compose down — containers persist across server reboots.
- Every fire-and-forget Task runs under TaskSupervisor (never bare `Task.start`).

## Container model (Docker Compose)

Each workspace's containers are orchestrated via Docker Compose. Agents write `Dockerfile` and `docker-compose.yml` directly to `.boomlooper/workspace/`. ServiceManager runs compose up/down. The code volume is the source of truth for project files — all containers mount it at `/workspace`, and all file operations (agent tools, terminal, VolumeIO) go through Docker.

```
Compose project: bl-{workspace_id}
  ├── workspace (built from Dockerfile, agents exec here, sleep infinity)
  ├── dev (built from Dockerfile, runs dev command)
  ├── postgres (stock service)
  └── redis (stock service)
```

All containers share a Docker network and the code volume. Container naming: `bl-{workspace_id}-{service}-1`.

### Volume-based architecture

All workspaces use Docker named volumes for code storage:

```
code-{workspace_id} (named volume)
  ├── workspace container mounts /workspace
  ├── dev container mounts /workspace
  └── inotify works between containers (same Linux filesystem)
```

- **Git projects**: `VolumeCloner.clone_into_volume` clones the repo using host git, then copies into volume
- **Local projects**: `VolumeIO.copy_to_volume` rsyncs code to volume on first start

### Container persistence

Containers survive server reboots:
- `ServiceManager.terminate` does NOT call `compose down`
- On startup, `ServiceManager.init` checks `Compose.ps` for running containers
- If found: reconnects state without rebuilding (`:reconnect` call)
- If not found: does full `compose up --build`
- `POST /system/reset` is the only path that calls `compose down`

## Docker interface

**Every Docker CLI call goes through `BoomLooper.Docker`.** No `System.cmd("docker", ...)` anywhere else.

| Function | Use case |
|----------|----------|
| `Docker.docker(args, opts)` | One-shot commands. Returns `{:ok, output}` or `{:error, output}`. Has timeout, telemetry, env options. |
| `Docker.stream(args, callback, opts)` | Long-running commands with streaming output. Calls `callback` per chunk. |
| `Docker.open_port(args, opts)` | Raw Port for custom stream handling (Observer events, terminal). |

`Docker.Observer` maintains an ETS cache of all `bl-*` containers and volumes, updated by `docker events` stream. LiveViews read from ETS (microseconds) instead of shelling out to docker (100ms+).

## MCP tool architecture

Each agent tool is a standalone module. No monolithic tool files.

```
lib/boom_looper/tools/
├── container.ex              ← toolkit (lists 20 tool modules in __tool_server__/0)
├── container/
│   ├── helpers.ex            ← shared: resolve_container, validate_path, etc.
│   ├── exec.ex               ← one tool
│   ├── exec_stream.ex
│   ├── write_file.ex
│   ├── read_file.ex
│   ├── edit.ex
│   ├── multi_edit.ex
│   ├── grep.ex
│   ├── glob.ex
│   ├── tree.ex
│   ├── logs.ex
│   ├── docker.ex
│   ├── docker_compose.ex
│   ├── inspect_env.ex
│   ├── inspect_service.ex
│   ├── service_containers.ex
│   ├── ports.ex
│   ├── probe_http.ex
│   ├── probe_formatter.ex
│   ├── read_files.ex
│   ├── workspace_info.ex
│   └── volumes.ex
├── agents.ex                 ← agent-to-agent tools
├── secrets.ex                ← secret management tools
└── workspace.ex              ← workspace metadata tools
```

**Tool module structure** (using `BoomLooper.Tool` macro):

```elixir
defmodule BoomLooper.Tools.Container.Exec do
  use BoomLooper.Tool,
    name: "exec",
    description: "Run a shell command inside the container.",
    params: [
      agent_id: {:string, required: true},
      command: {:string, required: true},
      timeout: {:integer, description: "Max seconds (default: 120)"}
    ]

  def execute(%{agent_id: id, command: cmd} = params, _assigns) do
    # tool logic
  end
end
```

The macro generates `__tool_name__/0`, `__description__/0`, `input_schema/0`. You just write `execute/2`. Params arrive with atom keys (SDK atomizes them via `safe_atomize_keys`).

**Tool output truncation:** Long command output is truncated for agents (via `Helpers.truncate_for_agent`, ~80 lines) to conserve context tokens. The full output is streamed to the chat UI for human viewers. This keeps agent context bounded while giving humans complete visibility.

**Discovery pipeline:**
1. `ChatAgent.ToolConfig.default_tools()` → `[Tools.Agents, Tools.Container, Tools.Secrets]`
2. `build_mcp_servers/1` calls `__tool_server__()` on each → `%{name => module}` map
3. `build_allowed_tools/2` iterates tools, builds `"mcp__server__tool"` strings
4. Passed to Claude SDK session → CLI contacts BEAM via JSONRPC for tool calls

## ChatAgent internals

Each `ChatAgent` is a GenServer owning a Claude Code SDK session (CLI subprocess).

**Message storage:** Reversed list internally for O(1) prepend. `append_message` returns `{state, msg}`. `summary/1` reverses before exposing to readers. Capped at 1000 messages in memory — the ETF agent log retains full history.

**Submodules:**
- `ChatAgent.Prompt` — system prompt construction
- `ChatAgent.ToolConfig` — MCP server/tool wiring
- `ChatAgent.Persistence` — ETF log append

**State flow:**
```
GenServer state (source of truth, reversed message list)
    ↓ summary(state) — reverses messages
ETS (read by LiveViews, get_state, get_message)
    ↓ PubSub broadcast (includes message with ID)
LiveViews (render updates)
```

**Session recovery:** ChatAgent auto-restarts dead CLI sessions with exponential backoff (1s → 2s → 4s, max 30s). Builds a resume message from recent activity so the new session can continue.

## LiveView architecture

LiveViews are thin — they handle events, delegate to modules, and render.

```
lib/boom_looper_web/live/
├── chat_live.ex              ← mount, handle_*, render (~850 lines)
├── chat_live/
│   ├── components.ex         ← imports all component submodules
│   ├── components/
│   │   ├── sidebar.ex        ← sidebar, service_item, volume_item, agent_list_item
│   │   ├── chat.ex           ← chat_header, agent_view, chat_panel, container_panel
│   │   ├── services.ex       ← service_log_view, console_view, all_services_view
│   │   ├── states.ex         ← booting_screen, empty_state
│   │   └── formatters.ex     ← time_ago, exit_reason, service_status_text (pure functions)
│   ├── agent_lifecycle.ex    ← spawn, select, list agents
│   ├── service_logs.ex       ← fetch, refresh service logs (async via TaskSupervisor)
│   ├── compose_check.ex      ← async compose file detection
│   └── messages.ex           ← chat_msg, streaming_bubble components
```

**Key patterns:**
- Mount renders instantly with loading skeletons. Slow data arrives via `start_async/3`.
- Docker.Observer provides container/volume state from ETS (zero docker calls from LiveViews).
- Service log fetching runs in TaskSupervisor — LiveView never blocks on `docker logs`.
- All shared state flows through GenServer → PubSub → all LiveViews.

## ETS tables

All owned by `StateKeeper`. Created once in `init/1`.

| Table | Type | Purpose |
|-------|------|---------|
| `:chat_agents` | set | Agent state summaries (read by LiveViews) |
| `:project_registry` | set | Project records |
| `:workspace_registry` | set | Workspace records |
| `:event_log` | ordered_set | System events (newest-first, capped at 200) |
| `:service_status_cache` | set | Service status per workspace |
| `:docker_observer` | set | Container/volume snapshot from Docker.Observer |
| `:boom_looper_evals` | set | Eval run state |

## Agent persistence

Agents and messages are persisted to an append-only ETF log at `~/.boomlooper/workspaces/{id}/.boomlooper/workspace/agents.log`.

On server restart:
1. ServiceManager detects running containers via `Compose.ps`
2. Calls `replay_agent_log` to restore agent state to ETS
3. Starts ChatAgent GenServers with `resume: true` for each restored agent
4. Each agent loads messages from ETS and starts a fresh Claude session

**Log format:** Length-prefixed binary records using `:erlang.term_to_binary`. Events: `{:agent, id, data}`, `{:msg, agent_id, msg}`, `{:msg_update, agent_id, msg_id, changes}`, `{:agent_removed, id}`.

## Telemetry

Key operations emit telemetry spans:

| Event | Module | Metadata |
|-------|--------|----------|
| `[:boom_looper, :docker, :command]` | `Docker.docker/2` | `%{args: args, timeout: timeout}` |
| `[:boom_looper, :compose, :up]` | `Compose.up/2` | `%{workspace_id: id}` |
| `[:boom_looper, :compose, :down]` | `Compose.down/2` | `%{workspace_id: id}` |
| `[:boom_looper, :agent, :message]` | `ChatAgent` | `%{agent_id: id, role: :user}` |

No subscribers configured by default — attach your own handlers for logging/metrics.

## Directory structure

```
# Code volume (Docker named volume code-{workspace_id})
/workspace/                     ← project root inside containers
└── .boomlooper/
    ├── repo/
    │   └── workspace.json      ← metadata (name, system prompt)
    └── workspace/
        ├── Dockerfile          ← agent-written
        └── docker-compose.yml  ← agent-written

# BoomLooper home directory
~/.boomlooper/
├── workspaces/
│   └── {workspace_id}/
│       └── .boomlooper/workspace/
│           ├── docker-compose.yml  ← processed by Compose (host copy)
│           └── agents.log          ← append-only agent state log
├── projects.json               ← persisted project list
└── secrets.json                ← user-level secret storage
```

## Terminal (interactive console)

The Terminal GenServer wraps `docker exec -it` via `script(1)` for PTY allocation. Without `script`, Erlang Ports don't provide a real TTY.

- macOS: `script -q /dev/null docker exec -it container sh`
- Linux: `script -qc "docker exec -it container sh" /dev/null`
- Fallback: `docker exec -i container sh` (no PTY)

Connected via Phoenix Channel (`terminal:container_name`). PubSub topic (`terminal_output:container_name`) is deliberately different from the channel topic to avoid double-delivery. Multiplayer — all viewers share one session. 50KB output buffer for late joiners.

## JS hooks

| Hook | Purpose |
|------|---------|
| `ScrollBottom` | Auto-scroll chat messages on mount + explicit push_event |
| `TailScroll` | Auto-scroll to bottom on mount AND every update (for log tailing) |
| `ChatForm` | Clear input after submit, auto-resize textarea |
| `CopySource` | Copy text/fetched content to clipboard |
| `Markdown` | Render markdown content via marked.js |
| `Terminal` | xterm.js terminal connected via Phoenix Channel |
