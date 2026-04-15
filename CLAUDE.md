# Boom Looper — Multi-Player Claude Code Runner

A Phoenix LiveView app that lets a team share and interact with Claude Code agents in real-time through a chat interface. Agents run code inside Docker containers.

**Multiplayer by design.** Two meanings:
1. **Multiple people** can watch and interact with agents simultaneously.
2. **One person, multiple windows** — tear off agent chats, service consoles, build logs into separate tabs. Every view has its own URL and stays in sync via PubSub.

All UI state is server-driven (assigns, PubSub). Never rely on client-side state.

## How it works

BoomLooper is a **Docker control plane** with **AI agents** wired into it. Dev environments are Docker all the way down — compose clusters, named volumes, container images. Code lives in Docker volumes. Agents and humans interact with it exclusively through Docker.

**The control plane:** Each project gets a Docker Compose cluster — a workspace container (where agents exec commands), dev server containers (running the app), and stock services (postgres, redis, etc.). Code lives in a named Docker volume (`bl-<workspace_id>-code`) mounted at `/workspace` in every container. Agents write `Dockerfile` and `docker-compose.yml` directly to `.boomlooper/workspace/`. BoomLooper manages the container lifecycle, monitors health, and reconnects to running containers across server restarts.

**Source adapters — the ingress layer:** Source adapters (`Source.Local`, `Source.GitHub`) are how code gets INTO the volume, but they don't participate in the dev environment. Local uses Mutagen to sync host filesystem to the Docker volume. GitHub clones via API into the volume. Once code is in the volume, everything is Docker — agents have NO host filesystem access when containers are running. See [docs/SOURCE_ADAPTERS.md](docs/SOURCE_ADAPTERS.md).

**The agents:** Claude Code sessions run as GenServer processes. Each agent exec's into the workspace container to read/write code and run commands. Agents use MCP tools from `boom-looper-container`: `exec` for commands, `write_file` for Dockerfile/docker-compose.yml, `docker_compose` for container lifecycle, `logs` for debugging. All tool operations go through Docker — `Docker.exec_in` for commands, `VolumeIO` for file I/O. Tool output is truncated for agents (via `Helpers.truncate_for_agent`, ~80 lines) to save context tokens, but streamed in full to the UI for humans. The setup agent bootstraps a project from scratch by examining the codebase and writing infrastructure files directly.

**The multiplayer layer:** Everything is wired through PubSub. Chat messages, terminal I/O, service status changes, build output — all broadcast to every connected viewer. LiveViews subscribe and render. The terminal system supports both browser (xterm.js via Phoenix Channel) and SSH access to the same shared session. Multiple people can watch an agent work, type in the same terminal, or monitor services simultaneously.

**The key insight:** agents and humans use the same tools and views. Agents use MCP tools (`exec`, `read_file`, `docker_compose`). Humans see the same data in the UI (service logs, file browser, terminal). The MCP tools are structured wrappers around the same Docker operations the terminal console uses. This means anything an agent does is visible, reproducible, and debuggable by a human.

## Docs

- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — System design, supervisor tree, container model, data flow
- **[docs/SECURITY.md](docs/SECURITY.md)** — Workspace boundary guarantees, how they're enforced, what's out of scope. **Read before touching tools, MCP servers, or compose processing.**
- **[docs/CONFIG.md](docs/CONFIG.md)** — Every env var, app-config key, module attribute, and on-disk config file in one place. Look here before adding a new setting.
- **[docs/TESTING.md](docs/TESTING.md)** — Test strategy, contracts, helpers, when to write tests
- **[docs/CODE_RULES.md](docs/CODE_RULES.md)** — Hard-won rules that prevent real bugs. **Read before editing code.**
- **[docs/SOURCE_ADAPTERS.md](docs/SOURCE_ADAPTERS.md)** — Source adapter rules (Local, GitHub)
- **[docs/EVALS.md](docs/EVALS.md)** — Eval runner, integrity rules, how to fix failures
- **[docs/IMPROVEMENTS.md](docs/IMPROVEMENTS.md)** — Prioritized backlog of scoped improvements. Add entries when you find something worth doing but not shipping today.
- **[plans/](plans/)** — Scoped design plans for features in flight. Read the relevant plan before implementing; update it when the plan evolves during implementation.

**Update docs when you ship a major change or feature.** Specifically:
- New MCP tool, compose rule, source adapter, or security boundary → update the doc that owns that concern (`SECURITY.md`, `SOURCE_ADAPTERS.md`, the tool toolkit's `@moduledoc`).
- New config key / env var / on-disk file → add a row to `CONFIG.md`.
- New architectural seam (supervisor, GenServer, data flow) → update the relevant section of `ARCHITECTURE.md`.
- Hard-won rule that prevents a real bug → add to `CODE_RULES.md` so the next contributor doesn't repeat the mistake.
- Finding worth tracking but not shipping → `IMPROVEMENTS.md`.
- Feature plan that spans multiple commits → `plans/<feature>.md` at start; delete or archive when merged.
Docs that silently drift are worse than no docs. The commit that ships the behavior change ships the doc change.

## Quick start

```bash
mix boom.setup     # installs deps, fixes Docker config, builds assets
mix boom.server    # starts the server with distributed node for remote access
```

Launch from any project directory: `open "http://localhost:4000/launch/SECRET?path=$(pwd)"`

## Remote access

When BoomLooper is running (`mix boom.server`), you can jack into it and run any Elixir:

```bash
# One-shot: evaluate a single expression
mix boom.rpc "BoomLooper.ChatAgent.list_agents()"
```

`mix boom.rpc` reads the cookie from `~/.boomlooper/cookie` automatically. Any valid Elixir expression works — ETS, GenServers, Registry, Docker, anything. Use this to inspect state, run evals, kill agents, check services, hot-reload code.

**Always use `mix boom.rpc` to verify your changes work on the live system.** Don't just compile and hope — jack in and check.

## Terminology

- **Project** = a git repo. Managed by `ProjectRegistry`.
- **Workspace** = a working directory (git worktree) within a project. Each gets its own containers, volumes, agents. Managed by `WorkspaceRegistry`.
- **WorkspaceSupervisor** = top-level DynamicSupervisor for all workspace subtrees.
- **WorkspaceGroup** = per-workspace Supervisor (ServiceManager + AgentSupervisor + ContainerMonitor).
- **Tool** = an MCP tool module under `Tools.Container.*`. One file per tool. Uses `BoomLooper.Tool` macro.
- **Toolkit** = `Tools.Container` — lists all tool modules in `__tool_server__/0`.
- Infrastructure files (`Dockerfile`, `docker-compose.yml`) live in `.boomlooper/workspace/` (gitignored). Metadata (`workspace.json` with project name, system prompt) lives in `.boomlooper/repo/` (can be tracked in git).
- User-level data in `~/.boomlooper/` (overridable with `BOOMLOOPER_HOME` env var).
- URLs: `/projects/:project_id/workspaces/:workspace_id/agents/:id`, `/messages/:agent_id/:msg_id`

## Key modules

| Module | Responsibility |
|--------|---------------|
| `Docker` | All Docker CLI calls — `docker/2`, `stream/3`, `open_port/1` |
| `Docker.Observer` | Event-driven ETS cache of container/volume state |
| `Compose` | Docker Compose operations (up, down, ps, logs) |
| `ChatAgent` | GenServer per agent session — messages, streaming, persistence |
| `ChatAgent.Prompt` | System prompt construction |
| `ChatAgent.ToolConfig` | MCP server/tool wiring |
| `ChatAgent.Persistence` | ETF log append for durability |
| `ProjectRegistry` | Project CRUD + ETS + disk persistence |
| `WorkspaceRegistry` | Workspace CRUD + ETS |
| `Source` | Behaviour for code ingress adapters (Local, GitHub) |
| `Source.Local` | Host ↔ volume sync via Mutagen + git worktrees |
| `VolumeManager` | Volume CRUD (create, remove, list) |
| `VolumeIO` | File read/write inside Docker volumes (no host filesystem) |
| `VolumeCloner` | Git clone → Docker volume pipeline |
| `StateKeeper` | Sole ETS table owner |
| `RegistryHelper` | DRY wrappers for Registry.lookup |
| `StreamBuffer` | Rolling-window streaming accumulator |
| `EventLog` | System event log (ETS + Logger) |
| `Tools.Container` | MCP toolkit — lists 20 tool modules |
| `Tools.Container.Helpers` | Shared tool helpers (resolve_container, validate_path) |
| `BoomLooper.Tool` | Macro for defining tool modules |

## Stack

Elixir 1.19 / OTP 28, Phoenix 1.7 / LiveView 1.1, Claude Code SDK (`claude_code`), Docker Compose, Tailwind CSS, xterm.js, Bandit. No database (ETS + GenServers).

## Architecture: Scaling & Persistence

**Workspace affinity model:** One workspace runs entirely on one node. Projects can span multiple nodes (different workspaces on different nodes), but a single workspace is always local to its node. This enables local storage without shared databases.

**Agent persistence:** Agents and messages are persisted to an append-only ETF log at `.boomlooper/workspace/agents.log`. On server restart:
1. ServiceManager detects running containers via `Compose.ps`
2. Calls `replay_agent_log` to restore agent state to ETS
3. Starts ChatAgent GenServers with `resume: true` for each restored agent
4. Each agent loads its messages from ETS and starts a fresh Claude session

ETS remains the runtime store for fast multiplayer access; the log is the durable backing store.

**Message storage:** Messages are stored as a reversed list internally for O(1) append. `append_message` returns `{state, msg}` — the msg has its ID assigned. `summary/1` reverses before exposing to readers. Capped at 1000 messages in memory; the ETF log retains the full history.

**Log format:** Length-prefixed binary records using `:erlang.term_to_binary`. Events: `{:agent, id, data}`, `{:msg, agent_id, msg}`, `{:msg_update, agent_id, msg_id, changes}`.

## Known issues

- Agent log compaction not implemented (append-only log grows, replay gets slower over time)
