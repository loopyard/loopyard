# Boom Looper — Multi-Player Claude Code Runner

A Phoenix LiveView app that lets a team share and interact with Claude Code agents in real-time through a chat interface. Agents run code inside Docker containers.

**Multiplayer by design.** Two meanings:
1. **Multiple people** can watch and interact with agents simultaneously.
2. **One person, multiple windows** — tear off agent chats, service consoles, build logs into separate tabs. Every view has its own URL and stays in sync via PubSub.

All UI state is server-driven (assigns, PubSub). Never rely on client-side state.

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

These rules exist because we learned them the hard way. Each one prevented a real bug.

### Every feature needs tests

Write failing tests first, then implement. Not optional. See [docs/TESTING.md](docs/TESTING.md).

### Isolate logic, test the real path

Extract logic into modules with clear boundaries. Don't bury behavior in LiveView private functions — if it has logic worth getting right, it belongs in its own module with its own tests.

**Test the real path, not a mock of it.** If users hit a bug through the websocket → channel → GenServer → Port stack, the test must exercise that same stack. A unit test that passes on an isolated layer while the integration is broken is worse than no test — it gives false confidence.

Concretely:
- **Inject dependencies** so tests can substitute local processes for Docker containers (e.g. Terminal accepts a `cmd` option so tests use a local shell instead of `docker exec`)
- **Test multiplayer** — spin up N subscribers, have each send input, assert each sees output exactly once. This catches PubSub topic collisions, stale connection duplication, and buffer replay overlap.
- **Prove the bug exists before fixing it.** Write a test that fails, THEN fix the code, THEN confirm the test passes. Don't ship a fix you haven't verified through a failing→passing test cycle.
- **Don't test rendering alone** — render tests prove HTML structure but not behavior. Test the accumulation, dedup, windowing, and state restoration logic as units.

### All state mutations go through GenServers

Never write directly to ETS from outside the owning GenServer. Use `ChatAgent.append_message_ets/2` and `ChatAgent.update_message/3` which route through the GenServer via casts. Direct ETS writes get overwritten.

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

On page load, initialize `build_log` from existing `:build` message content. TailScroll hook auto-scrolls on mount and update.

### Operations must be idempotent

Check if running before starting. Never `docker rm -f` then `docker run` unconditionally.

### Everything through Dockerfiles, never runtime scripts

Never `docker exec apt-get`. It doesn't persist across container restarts.

### Auto-restart dead CLI sessions

ChatAgent checks `session_alive?` before every send. Restarts silently. No auto-replay (causes crash loops).

## Terminology

- **Project** = a git repo. Managed by `ProjectRegistry`.
- **Workspace** = a working directory (git worktree) within a project. Each gets its own containers, volumes, agents.
- **WorkspaceSupervisor** = top-level DynamicSupervisor for all workspace subtrees.
- **WorkspaceGroup** = per-workspace Supervisor (ServiceManager + AgentSupervisor + ContainerMonitor).
- Config lives in `.boomlooper/repo/` (tracked in git). Generated files in `.boomlooper/workspace/` (gitignored).
- URLs: `/projects/:project_id/workspaces/:workspace_id/agents/:id`, `/messages/:agent_id/:msg_id`

## Stack

Elixir 1.19 / OTP 28, Phoenix 1.7 / LiveView 1.1, Claude Code SDK (`claude_code`), Docker Compose, Tailwind CSS, xterm.js, Bandit. No database (ETS + GenServers).

## Known issues

- ETS state lost on server restart (containers persist, projects/agents don't)
- Agent message history grows unbounded (future: SQLite)
- Secrets tests fail in sandbox (filesystem permissions)
