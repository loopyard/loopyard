# Boom Looper — Multi-Player Claude Code Runner

A Phoenix LiveView app that lets a team share and interact with Claude Code agents in real-time through a chat interface. Agents run code inside Docker containers.

**Multiplayer by design.** Two meanings:
1. **Multiple people** can watch and interact with agents simultaneously.
2. **One person, multiple windows** — tear off agent chats, service consoles, build logs into separate tabs. Every view has its own URL and stays in sync via PubSub.

All UI state is server-driven (assigns, PubSub). Never rely on client-side state.

## How it works

BoomLooper is a **Docker control plane** with **AI agents** wired into it.

**The control plane:** Each project gets a Docker Compose stack — a workspace container (where agents exec commands), dev server containers (running the app), and stock services (postgres, redis, etc.). BoomLooper generates the Dockerfile and docker-compose.yml from a config file (`.boomlooper/repo/workspace.json`), manages the container lifecycle, monitors health, and reconnects to running containers across server restarts.

**The agents:** Claude Code sessions run as GenServer processes. Each agent exec's into the workspace container to read/write code and run commands. Agents have MCP tools for controlling their infrastructure — setting the Dockerfile, adding services, rebuilding containers, running commands. The setup agent bootstraps a project from scratch by examining the codebase and writing the workspace config.

**The multiplayer layer:** Everything is wired through PubSub. Chat messages, terminal I/O, service status changes, build output — all broadcast to every connected viewer. LiveViews subscribe and render. The terminal system supports both browser (xterm.js via Phoenix Channel) and SSH access to the same shared session. Multiple people can watch an agent work, type in the same terminal, or monitor services simultaneously.

**The key insight:** agents don't get special access. They use the same `docker exec` path that the terminal console uses. The workspace config they write is the same config a human could edit. The MCP tools are just structured wrappers around the same Docker and file operations. This means anything an agent does is visible, reproducible, and debuggable by a human.

## Docs

- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — System design, supervisor tree, container model, data flow
- **[docs/TESTING.md](docs/TESTING.md)** — Test strategy, contracts, helpers, when to write tests

## Quick start

```bash
export MIX_HOME="$PWD/.mix_home" HEX_HOME="$PWD/.hex_home"
mix local.hex --force && mix deps.get && mix assets.setup && mix assets.build
mix phx.server
```

Launch from any project directory: `open "http://localhost:4000/launch/SECRET?path=$(pwd)"`

## System tools

```bash
curl localhost:4000/system/debug                     # Dump system state
curl -X POST localhost:4000/system/reset             # Nuclear reset (kills containers)
curl -X POST localhost:4000/system/reset/containers  # Kill containers only
```

## Code rules

These rules exist because we learned them the hard way. Each one prevented a real bug. If you break one, you will ship a bug that wastes hours to debug.

### Every feature needs tests — no exceptions

Write a failing test first, then implement. Not optional. See [docs/TESTING.md](docs/TESTING.md).

If you're fixing a bug, write a test that reproduces it BEFORE writing the fix. Run the test, watch it fail, then fix the code, then watch it pass. If you skip this, you have no proof the fix works. We've shipped "fixes" multiple times that didn't actually fix anything because the test wasn't written first.

### Isolate logic into testable modules

Don't bury behavior in LiveView private functions. If it has logic worth getting right, it belongs in its own module with its own tests. LiveViews should be thin — they handle events, delegate to modules, and render.

**Examples of what to extract:**
- `StreamBuffer` — streaming accumulation logic extracted from chat_live.ex private functions. 31 unit tests cover rolling window, upsert, restore, boundary conditions.
- `Terminal.build_cmd/1` — command construction extracted as a public function so tests can validate the PTY setup without Docker.
- `LogViewer` — rendering components extracted to `BoomLooperWeb.Components.LogViewer` with their own test file.

**The pattern:** if you find yourself writing complex logic inside `defp` in a LiveView, stop. Extract it. Test it. Wire the LiveView to call it.

### Keep tests fast

Unit tests should run in under 2 seconds total. If a test needs Docker, external services, or takes >1 second, tag it with `@tag :docker` or `@tag :slow` and exclude from default runs. Run full suite in CI.

**Example:** `AgentLog` tests run in 0.1s because they use temp files and injected ETS tables, not real workspaces.

### Test the real path, not a mock of it

If users hit a bug through the websocket → channel → GenServer → Port stack, the test must exercise that same stack. A unit test that passes on an isolated layer while the integration is broken is worse than no test — it gives false confidence.

**We learned this the hard way:** Terminal unit tests passed (PTY echo was fine in isolation) while users saw double-echo in the browser. The bug was a PubSub topic collision between the Terminal output topic and the Phoenix channel topic — only visible when the full websocket stack was exercised. We found it by writing `terminal_integration_test.exs` that connects via the channel, sends input, and asserts output appears exactly once.

Concretely:
- **Inject dependencies** so tests can substitute local processes for Docker containers (e.g. Terminal accepts a `cmd` option so tests use a local shell instead of `docker exec`)
- **Test multiplayer** — spin up N subscribers, have each send input, assert each sees output exactly once. This catches PubSub topic collisions, stale connection duplication, and buffer replay overlap.
- **Prove the bug exists before fixing it.** Write a test that fails, THEN fix the code, THEN confirm the test passes. Don't ship a fix you haven't verified through a failing→passing test cycle.
- **Don't test rendering alone** — render tests prove HTML structure but not behavior. Test the accumulation, dedup, windowing, and state restoration logic as units.

### All state mutations go through GenServers

Never write directly to ETS from outside the owning GenServer. Use `ChatAgent.append_message_ets/2` and `ChatAgent.update_message/3` which route through the GenServer via casts. Direct ETS writes get overwritten.

### Never modify shared state in assigns directly

If other viewers should see a change, it must go through GenServer → PubSub → all LiveViews. Never update `messages`, `agents`, `service_statuses`, or any shared data in socket assigns directly from a `handle_event`. Call the GenServer and let the PubSub broadcast update all viewers.

Local assigns are only for per-viewer UI state (which tab is active, whether a rename input is open).

**The bug this prevents:** we had optimistic local message adds — the sender's LiveView added the user message directly to assigns, and the PubSub handler skipped `:user` role messages to avoid duplication. Result: other viewers never saw what the user typed. The fix: remove all optimistic adds, let every message flow through PubSub.

### PubSub topics must not collide with channel topics

Phoenix's channel transport subscribes to the channel topic string internally. If your GenServer broadcasts on the SAME topic string, the transport receives both the raw broadcast AND the channel's push — doubling every message. Use distinct topic strings: `"terminal_output:#{id}"` for GenServer broadcasts vs `"terminal:#{id}"` for the channel topic.

### Multiplayer is the default, not a feature

Every new feature must work with multiple viewers. Before shipping:
1. Can two browser tabs see the same state?
2. If one tab makes a change, does the other tab update?
3. If someone joins late, do they see the current state?
4. If someone clears/resets, does everyone see it?

This applies to chat messages, terminal sessions, service statuses, build output — everything.

### No side effects in LiveView mount or handle_params

Mount is **read-only**. Never start services, create containers, or modify external state on mount.

### Views observe, infrastructure acts

Views read from ETS/GenServers. They never create or modify infrastructure state. Infrastructure modules never depend on web modules.

### Containers persist across server reboots

`ServiceManager.terminate` does NOT call `compose down`. On restart, `init` detects running containers via `Compose.ps` and reconnects. Only `POST /system/reset` tears down containers.

### Message URL rules

- Real `<a href>` with `target="_blank" rel="noopener"`. No JS hacks.
- EVERY broadcast must include the message `:id`. Broadcast `List.last(state.messages)` after `append_message`.
- No tokens — simple URLs: `/messages/:agent_id/:msg_id`

### Streaming sync

Use `StreamBuffer` for all "show existing content + stream new data" patterns. It handles rolling byte windows, message upsert, and page-reload restoration. Don't reinvent this in LiveView assigns.

### Operations must be idempotent

Check if running before starting. Never `docker rm -f` then `docker run` unconditionally.

### Everything through Dockerfiles, never runtime scripts

Never `docker exec apt-get`. It doesn't persist across container restarts.

### Auto-restart dead CLI sessions

ChatAgent checks `session_alive?` before every send. Restarts silently. No auto-replay (causes crash loops).

### Keep it simple

Don't add infrastructure users have to install, configure, or manage. If a feature requires `sudo`, system packages, or manual setup steps, it's too complex. The app should work out of the box with `mix phx.server`.

Don't add toggles for things that should just be on. Don't add config files for things that have sensible defaults. Don't add "advanced" sections that hide complexity — either the feature is simple enough to be always-on, or it's not ready.

## Terminology

- **Project** = a git repo. Managed by `ProjectRegistry`.
- **Workspace** = a working directory (git worktree) within a project. Each gets its own containers, volumes, agents.
- **WorkspaceSupervisor** = top-level DynamicSupervisor for all workspace subtrees.
- **WorkspaceGroup** = per-workspace Supervisor (ServiceManager + AgentSupervisor + ContainerMonitor).
- Config lives in `.boomlooper/repo/` (tracked in git). Generated files in `.boomlooper/workspace/` (gitignored).
- User-level data in `~/.boomlooper/` (overridable with `BOOMLOOPER_HOME` env var).
- URLs: `/projects/:project_id/workspaces/:workspace_id/agents/:id`, `/messages/:agent_id/:msg_id`

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

**Log format:** Length-prefixed binary records using `:erlang.term_to_binary`. Events: `{:agent, id, data}`, `{:msg, agent_id, msg}`, `{:msg_update, agent_id, msg_id, changes}`.

## Known issues

- Agent message history grows unbounded (future: log compaction)
