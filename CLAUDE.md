# Loopyard — Multi-Player Claude Code Runner

A Phoenix LiveView app that lets a team share and interact with Claude Code agents in real-time through a chat interface. Agents run code inside Docker containers.

**Multiplayer by design.** Two meanings:
1. **Multiple people** can watch and interact with agents simultaneously.
2. **One person, multiple windows** — tear off agent chats, service consoles, build logs into separate tabs. Every view has its own URL and stays in sync via PubSub.

All UI state is server-driven (assigns, PubSub). Never rely on client-side state.

## How it works

Loopyard is a **Docker control plane** with **AI agents** wired into it. Dev environments are Docker all the way down — compose clusters, named volumes, container images. Code lives in Docker volumes. Agents and humans interact with it exclusively through Docker.

**The control plane:** Each project gets a Docker Compose cluster — a workspace container (where agents exec commands), dev server containers (running the app), and stock services (postgres, redis, etc.). Code lives in a named Docker volume (`loopyard-<workspace_id>-code`) mounted at `/workspace` in every container. Agents write `Dockerfile` and `docker-compose.yml` directly to `.loopyard/workspace/`. Loopyard manages the container lifecycle, monitors health, and reconnects to running containers across server restarts.

**Source adapters — the ingress layer:** Source adapters (`Source.Local`, `Source.GitHub`) are how code gets INTO the volume, but they don't participate in the dev environment. Local uses Mutagen to sync host filesystem to the Docker volume. GitHub clones via API into the volume. Once code is in the volume, everything is Docker — agents have NO host filesystem access when containers are running. See [docs/SOURCE_ADAPTERS.md](docs/SOURCE_ADAPTERS.md).

**The agents:** Claude Code sessions run as GenServer processes. Each agent exec's into the workspace container to read/write code and run commands. Agents use MCP tools from `loopyard-container`: `exec` for commands, `write_file` for Dockerfile/docker-compose.yml, `docker_compose` for container lifecycle, `logs` for debugging. All tool operations go through Docker — `Docker.exec_in` for commands, `VolumeIO` for file I/O. Tool output is truncated for agents (via `Helpers.truncate_for_agent`, ~80 lines) to save context tokens, but streamed in full to the UI for humans.

**One self-determining agent — no setup-vs-coding split.** There is a single agent type (`priv/agents/coding/agent.md`). It reads the situation before acting: it runs `service_status` and inspects `/workspace`, then bootstraps the dev environment ONLY if it's actually missing (no `.loopyard/workspace/docker-compose.yml`), brings it back up if it exists but is down, and otherwise just codes without re-scaffolding a working environment. The setup playbook (`setup_guide.md`) and per-stack guides (`stacks/`) live alongside the agent prompt in `priv/agents/coding/`; the agent reads them on demand via `read_agent_file` (relative paths). There is no separate "setup agent."

**The multiplayer layer:** Everything is wired through PubSub. Chat messages, terminal I/O, service status changes, build output — all broadcast to every connected viewer. LiveViews subscribe and render. The terminal system supports both browser (xterm.js via Phoenix Channel) and SSH access to the same shared session. Multiple people can watch an agent work, type in the same terminal, or monitor services simultaneously.

**The key insight:** agents and humans use the same tools and views. Agents use MCP tools (`exec`, `read_file`, `docker_compose`). Humans see the same data in the UI (service logs, file browser, terminal). The MCP tools are structured wrappers around the same Docker operations the terminal console uses. This means anything an agent does is visible, reproducible, and debuggable by a human.

## Coordination hardening (harden-resume-state)

The coordination layer went through a sprint of hardening moves (see [plans/coordination-hardening.md](plans/coordination-hardening.md) and the two follow-up audits). Landed surfaces + rules a new contributor needs to know:

**Observability surfaces (all at `/system`):**
- `/system/events` — live event tap (ring buffer, per-topic rate)
- `/system/sagas` — multi-step ops + rollback + journal state
- `/system/quarantine` — crash-looping actors, release controls
- `/system/orphans` — tracked resources without a live owner
- `/system/recovery` — checkpointer snapshot size/age, last boot replay time
- `/system/reconcilers` — drift detection runs
- `/system` — aggregated health map (`:healthy | :degraded | :down` per component)

**Adding a new broadcast event:**
1. Add a struct to the relevant publisher module in `lib/loopyard/events/` (e.g. `Loopyard.Events.ChatAgent.SomeEvent`).
2. Add a `publish/1` clause for the struct.
3. NEVER call `Phoenix.PubSub.broadcast/3` outside `lib/loopyard/events/`. The `test/loopyard/pubsub_boundary_test.exs` CI test will fail if you do.
4. Every subscriber behaviour gains a required `@callback on_<event>(struct, socket)`. Missing callback = compile warning (no `@optional_callbacks`).

**Adding a new LV subscriber:**
1. `@behaviour Loopyard.Events.<Topic>.Subscriber`
2. Implement every `on_*` callback explicitly (even if just `{:noreply, socket}`) — we do not use `@optional_callbacks`.
3. Standard dispatch: one `handle_info/2` per event struct that delegates to the callback.

**Adding a new state-machine actor (future):**
Move #1 (pure transition functions) and Move #5 (deadlines) are deferred for a future session. When they ship, each actor will expose `step(state, event) :: {:ok, new_state, side_effects}` per the plan. Until then, follow the pattern of `Loopyard.ChatAgent.StateMachine` (transition guards in a pure module, GenServer calls into it).

**Retry patterns:**
- Synchronous callers (tight retry loops, non-GenServer code) → `Loopyard.Retry.run/2`.
- Async / event-driven callers (GenServer crash recovery via `handle_info`) → `Loopyard.Retry.backoff_ms/2` + `Process.send_after`. NEVER `Process.sleep` inside a `handle_info`.

**Resource ownership:**
- If "resource X dies when process Y dies" is the intended semantic, use `Loopyard.Resources.track/4`. The Janitor runs the release fn on owner DOWN.
- If the resource must outlive the owner's restart (e.g. Mutagen sessions in `SyncMonitor`), DO NOT use `Resources.track`. Use ad-hoc `terminate/2` cleanup and document it.

**ETS ownership:** `Loopyard.StateKeeper` is the sole ETS table owner. Never call `:ets.new/2` elsewhere — add your table to `StateKeeper`'s `@tables` list.

## Agent reliability invariants (`plans/agent-sanity.md`)

The ChatAgent went through a second hardening sweep focused on
"conversation survives restart" + "when it can't, the user knows why."
Rules a contributor needs to know:

**Conversation continuity across CLI / server restart:**
- The Claude CLI subprocess has a `session_id` that the SDK tracks
  per live `ClaudeCode.Session` pid. We mirror it onto
  `state.claude_session_id` on every `%Event.SessionResult{}` and
  persist it via `summary/1` → ETF log.
- Every path that spawns a new CLI must go through
  `session_opts_with_resume/1` so `resume: <claude_session_id>` is
  passed to the SDK. That's what makes the new CLI continue the same
  conversation instead of booting amnesic. The four sites:
  `:restart_session` cast, `{:stream_error, "CLI session exited", _}`
  recovery, `dispatch_retry_session` (backoff retry),
  `ensure_session_alive` (pre-`send_message`).
- `init_resume` threads the saved `claude_session_id` through too —
  Loopyard server restart doesn't drop the conversation.

**Error messages follow WHY / CONSEQUENCE / ACTION.** Every
`role: :error` message in the ChatAgent:
1. Names what failed at the system level.
2. States what won't work + what's still preserved.
3. Tells the user exactly how to recover (which command, which UI
   page, which order).
Single-line terse errors are for developers, not operators. When
adding a new error path, follow the existing pattern.

**Every reset-to-idle path clears transient state:**
- `active_tool: nil` (UI spinner doesn't stick)
- `in_flight_partial: ""` (see below)
- `tool_calls_this_turn: 0`, `tool_runaway_warned: false`,
  `last_tool_call: nil` (loop detection resets per turn)
- `context_warning_sent: false` (window warning re-fires if still at
  threshold)

**Stream events must carry `stream_ref`.** Shape is
`{:stream_event, id, stream_ref, event}`. The handler drops events
whose ref doesn't match `state.stream_ref` — otherwise late events
from a replaced session corrupt the new state.

**Partial-text preservation.** On `:stream_error` /
`:stream_timeout` / `:stop` mid-turn, if `state.in_flight_partial`
is non-empty, `finalize_partial_on_stream_interrupt/3` persists it
as an assistant message tagged `partial: true` with a
"⚠ Truncated — …" marker. Without it, partials shown live in the
browser vanish on refresh.

**Bulletproof `send_message` input:**
- Non-binary payload → logged + rejected, no crash.
- `byte_size(text) > @max_message_bytes` (1MB) → rejected with an
  inline error.
- While `:rate_limited` or `:auth_expired`: record the message but
  don't hit the CLI; surface an explanation.
- While `:thinking` or `:backoff`: enqueue on `state.pending_sends`.
  FIFO drain via `drain_pending_sends/1` on turn completion.

**Catchalls on every callback.** `handle_cast(msg, state)`,
`handle_call(msg, _from, state)`, and `handle_info(msg, state)` all
log + fire `[:loopyard, :actor, :unknown_message]` telemetry and
return normally. Unknown messages never crash the GenServer.

**Resource tracking for the CLI OS pid.** After every
`start_session` call the agent registers the Claude CLI subprocess
with `Resources.track(self(), :claude_cli, os_pid, release_fn)`. On
agent DOWN (any reason, including `:brutal_kill`) the Janitor
SIGKILLs the OS pid. `terminate/2` does NOT kill directly.

**Prompt-drift detection.** `start_session` returns a SHA-256 of the
system prompt. `init_resume` compares to the saved hash; mismatch
surfaces an inline "System prompt changed since last boot" marker
+ `[:loopyard, :agent, :prompt_drift]` telemetry.

**Idle-agent CLI reap.** After `:agent_idle_reap_hours` (default 4h)
of `:idle` + captured `claude_session_id`, the reaper stops the CLI
subprocess + clears `state.session`. Next `:send_message` spawns a
fresh CLI with `resume:` — user sees "Reconnected (resumed
conversation …)" just like any crash recovery.

**Tool-call loop + runaway detection.**
`@tool_loop_threshold = 5` same-tool-same-input repeats → warn once.
`@turn_tool_limit = 50` tool calls in one turn (any shape) → warn
once per turn. Both reset on `stream_done`.

**Timeouts.** `get_state/1` and `list_agents/0` use 500ms call
timeouts with ETS fallback — a wedged agent doesn't hang the UI.
`terminate/2` caps `backend.stop` at 3s via `Task.yield` +
`Task.shutdown`. Stream task has a 10-min safety timer via
`:stream_timeout` ref-tagged.

## Harness backend seam (ACP-first)

**The Harness behaviour is the pluggable harness seam.**
`Loopyard.Harness` (`lib/loopyard/harness.ex`) defines
`start_session/1`, `stream/2`, `stop/1`, `session_alive?/1`,
`session_id/1`. Everything above it (ChatAgent, StreamHandler,
multiplayer fan-out) consumes neutral `Loopyard.Agent.Event` structs,
so only the event *source* differs per backend. Implementations:
`Harness.Claude` (the SDK/CLI today), `Harness.ACP`
(`harness/acp.ex` — drives a **real** Claude/Codex harness over the
Agent Client Protocol, JSON-RPC over stdio), `Harness.Fake` (tests).
ACP is the north-star direction (#3): run the real harness
*in-container* (`docker exec -i <work> claude-code-acp`) against the
mounted code volume, instead of reimplementing the agent loop. ACP is
implemented + tested but not yet the default backend — see
`docs/IMPROVEMENTS.md` for the open ACP gaps (permission round-trip,
cancel/interrupt, resume, token cost, session_opts shape).

**Tool rendering is harness-agnostic — classify by KIND, never by
name.** Different backends emit different tool *names* for the same
act (the in-container ACP harness uses Claude Code's NATIVE tools —
`Bash`/`Read`/`Grep`/`Edit`/`Write` — while the in-process path uses
loopyard MCP names like `mcp__loopyard-container__exec`). The UI must
never match those raw names; it renders off a neutral
`t:Loopyard.Agent.ToolKind.t/0` (`:command | :read | :grep | :edit |
:write | :generic`). `Loopyard.Agent.ToolKind` is the ONE place tool
vocabulary is known; `%Event.ToolCall{}` carries an optional `kind` a
backend may stamp itself, and `StreamHandler` falls back to
`ToolKind.classify(name)`, storing the result as `tool_kind` on the
message. A NEW harness plugs into the UI without touching it — name
your tools recognizably, or stamp `kind` on the event. Adding a UI
tool-name string-match anywhere else re-couples the presentation layer
to a backend's vocabulary — extend `ToolKind` instead.

**Inbox vs. turn execution — the durability boundary.** Loopyard owns
the **durable message inbox**: ordering, the persisted message log, the
`pending_sends` FIFO queue, and the rate-limit/auth/backoff gating.
The harness (whichever Backend) owns only **turn execution** — taking a
prompt and streaming a response. This split is why a harness restart
doesn't lose messages: the inbox is Loopyard state, not harness state.

**ACP MCP bridge — Loopyard's control-plane tools in-container.** The
in-container ACP harness can't use the in-process Elixir MCP servers the
ClaudeCode backend uses, so it reaches Loopyard's *control-plane* tools
(ports, service lifecycle, the approval-gated fork/integrate/delete flows,
ask/secret round-trips) over HTTP. `Loopyard.MCP.acp_mcp_servers/2` builds
the ACP `session/new` `mcpServers` spec (Initializer injects it as
`:acp_mcp_servers` for ACP agents); `LoopyardWeb.MCP.Listener` is a
**dedicated Bandit endpoint on `0.0.0.0:<LOOPYARD_MCP_PORT>`** (default 4030,
separate from the loopback-only main endpoint) so a workspace container can
reach it via `host.docker.internal`. Every call is bearer-authed
(`Loopyard.MCP.Token`, per-agent scoped) and dispatched by
`Loopyard.MCP.ToolRouter` to the *same* `Loopyard.Tool` `execute/2` the
in-process path calls — the identity comes from the token, never the payload.
Only the control-plane subset is exposed (`ToolConfig.acp_control_plane_tools/0`);
fs/exec tools are omitted (the container has native Read/Write/Bash). This is
the one Loopyard surface reachable from inside a container — read
docs/SECURITY.md → "ACP MCP bridge" before touching it.

## Fork readiness (provision-before-available)

A fork is fully provisioned **before** it becomes available — "Open"
lands you on a live agent, never a blank scrambling workspace. The flow
(`propose_fork` → `Onboarding.fork_from_workspace/4`):
1. Copy the source workspace's code volume (working tree + `.loopyard`
   infra + git history) onto the new branch's OWN volume. Stale
   pid/socket files are scrubbed during the copy.
2. Normalize the compose code-volume names to the fork's own volume
   (`Compose.normalize_code_volume_names`) — fork-safety: the fork must
   never mount the source's volume.
3. Boot the fork's preview cluster from the `.loopyard` config it carries
   (`Onboarding.start_preview_async/1`, async + best-effort) — a cloned
   workspace comes up **running** with a live dev server + port, not a
   dead sidebar. No-ops when there's no compose. (This used to be gated on
   the source's cluster running, via a `container_running?` check for a
   compose service literally named "workspace" — which real compose files
   never have, so the gate was always false and forks never booted.)
4. Spawn the branch's agent via the unified `Onboarding.spawn_agent/2`
   (the single backend-spawn path shared by the LiveView "New agent"
   and provisioning flows).
Each phase streams into the approval card via the `progress` callback;
the card resolves to "Ready — open `<branch>` →".

**UI-created workspaces (non-canonical Local projects) take a different
path** — `add_workspace` → the `Workspace.Setup` saga (`:worktree` copies
`.loopyard`, `:volume`, `:seeding`). On success (`finalize_saga`) it too
calls `Onboarding.start_preview_async/1`, so *every* provisioning path
boots the cloned config once cloning is done — not just forks.

## Send reliability (no silent loss)

- **Send waits for a server ack before clearing the input.** The
  `send_message` LiveView event replies `%{ok: true}`; the `ChatForm`
  JS hook keeps your typed text until that reply lands (`app.js`). A
  disconnected socket → no ack → text stays, nothing is dropped.
- **Connection-lost banner** (`#conn-banner`) reveals after a short
  grace period when the websocket is down, hides on reconnect — the
  "is it safe to type" signal.
- **Harness-status block** in the agent sidebar
  (`context_panel.ex` → `harness_status/1`) is the one place to glance
  at to know harness state (Ready / Starting / Reconnecting / offline /
  rate-limited), with a plain-language consequence line.

## Docs

- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — System design, supervisor tree, container model, data flow
- **[docs/SECURITY.md](docs/SECURITY.md)** — Workspace boundary guarantees, how they're enforced, what's out of scope. **Read before touching tools, MCP servers, or compose processing.**
- **[docs/CONFIG.md](docs/CONFIG.md)** — Every env var, app-config key, module attribute, and on-disk config file in one place. Look here before adding a new setting.
- **[docs/TESTING.md](docs/TESTING.md)** — Test strategy, contracts, helpers, when to write tests
- **[docs/CODE_RULES.md](docs/CODE_RULES.md)** — Hard-won rules that prevent real bugs. **Read before editing code.**
- **[docs/SOURCE_ADAPTERS.md](docs/SOURCE_ADAPTERS.md)** — Source adapter rules (Local, GitHub)
- **[docs/GIT.md](docs/GIT.md)** — Git hygiene: atomic commits, sane messages, branch discipline
- **[docs/EVALS.md](docs/EVALS.md)** — Eval runner, integrity rules, how to fix failures
- **[docs/HOSTING.md](docs/HOSTING.md)** — Running Loopyard as an always-on local server: macOS power management, keeping it reachable over LAN
- **[docs/IMPROVEMENTS.md](docs/IMPROVEMENTS.md)** — Prioritized backlog of scoped improvements. Add entries when you find something worth doing but not shipping today.
- **[plans/](plans/)** — Scoped design plans for features in flight. Read the relevant plan before implementing; update it when the plan evolves during implementation.
- **[packages/aural/README.md](packages/aural/README.md)** — The `:aural` audio package (lives in this repo, also consumed by the marketing site via git+sparse). API surface, channel model, telemetry, DOM contract.

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
mix loopyard.setup     # installs deps, fixes Docker config, builds assets
mix loopyard.server    # starts the server with distributed node for remote access
```

Launch from any project directory: `open "http://localhost:4000/launch/SECRET?path=$(pwd)"`

## Remote access

When Loopyard is running (`mix loopyard.server`), you can jack into it and run any Elixir:

```bash
# One-shot: evaluate a single expression
mix loopyard.rpc "Loopyard.ChatAgent.list_agents()"
```

`mix loopyard.rpc` reads the cookie from `~/.loopyard/cookie` automatically. Any valid Elixir expression works — ETS, GenServers, Registry, Docker, anything. Use this to inspect state, run evals, kill agents, check services, hot-reload code.

**Always verify your changes work on the live system.** Don't just compile and hope.

Two ways in:
- **Shell-based:** `mix loopyard.rpc "..."` — works from any terminal, scriptable, no Claude session required. The primary tool when iterating in a terminal or writing one-off diagnostics.
- **In-session (Tidewave MCP):** when Claude Code is connected to the local Tidewave MCP server, it can `eval` Elixir, fetch logs, and introspect processes directly without shelling out. Setup once:
  ```bash
  claude mcp add --transport http tidewave http://localhost:4000/tidewave/mcp
  ```
  The endpoint is registered in `LoopyardWeb.Endpoint` inside the `code_reloading?` block — dev only, never enabled in prod.

## Terminology

- **Project** = a git repo. Managed by `ProjectRegistry`.
- **Workspace** = a working directory (git worktree) within a project. Each gets its own containers, volumes, agents. Managed by `WorkspaceRegistry`.
- **WorkspaceSupervisor** = top-level DynamicSupervisor for all workspace subtrees.
- **WorkspaceGroup** = per-workspace Supervisor (ServiceManager + AgentSupervisor + ContainerMonitor).
- **Tool** = an MCP tool module under `Tools.Container.*`. One file per tool. Uses `Loopyard.Tool` macro.
- **Toolkit** = `Tools.Container` — lists all tool modules in `__tool_server__/0`.
- Infrastructure files (`Dockerfile`, `docker-compose.yml`) live in `.loopyard/workspace/` (gitignored). Metadata (`workspace.json` with project name, system prompt) lives in `.loopyard/repo/` (can be tracked in git).
- User-level data in `~/.loopyard/` (overridable with `LOOPYARD_HOME` env var).
- URLs: `/projects/:project_id/workspaces/:workspace_id/agents/:id`, `/messages/:agent_id/:msg_id`

## Key modules

| Module | Responsibility |
|--------|---------------|
| `Docker` | All Docker CLI calls — `docker/2`, `stream/3`, `open_port/1` |
| `Docker.Observer` | Event-driven ETS cache of container/volume state |
| `Compose` | Docker Compose operations (up, down, ps, logs) |
| `ChatAgent` | GenServer reactor — message routing, public API |
| `ChatAgent.StreamHandler` | Stream event processing, rate limits, tool loop detection |
| `ChatAgent.Initializer` | Init/resume/fresh state building, session startup |
| `ChatAgent.SessionManager` | CLI lifecycle: ensure_alive, stop, retry, OS pid tracking |
| `ChatAgent.IdleReaper` | Auto-stop agents idle past threshold |
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
| `Events.*` | Per-topic publisher modules (sole PubSub broadcasters) |
| `Retry` | Shared retry helper (`run/2` sync, `backoff_ms/2` async) |
| `Resources` + `Resources.Janitor` | Owner-tracked resource cleanup on DOWN |
| `Saga` + `Saga.Journal` + `Saga.Recorder` | Multi-step ops with rollback + durable journal |
| `ChatAgent.RestartController` | Per-workspace quarantine of crash-looping agents |
| `AgentLog.Checkpointer` | Periodic snapshot + log truncation (bounded boot replay) |
| `Agent.Reconciler` | ETS-vs-registry drift detection every 30s |
| `Health` | Aggregated subsystem health map for `/system` |
| `WorkspaceTree` | The projects→workspaces→agents overview tree (pure ETS) + per-workspace derived signals (`needs_you`/`broken`/`changes`) |
| `ChangeCounts` | Event-driven cache of per-workspace changed-file counts (±N badge) — async git_status on agent idle + sweep, `:ws_change_counts` ETS |
| `Events.Tap` | Ring buffer of broadcasts for `/system/events` |
| `PortRegistry` | Global port pool, proxy lifecycle, Observer reconciliation |
| `PortExposer` | Per-port TCP proxy GenServer (loopback ↔ network toggle) |
| `PortStore` | JSON persistence for port assignments (`ports.json`) |
| `Tools.Container` | MCP toolkit — lists 22 tool modules |
| `Tools.Container.Helpers` | Shared tool helpers (resolve_container, validate_path) |
| `Loopyard.Tool` | Macro for defining tool modules |
| `Loopyard.MCP` | ACP MCP bridge entry — builds the `mcpServers` spec + container-reachable base URL |
| `Loopyard.MCP.Token` | Per-agent scoped bearer tokens (`Phoenix.Token`) for the MCP bridge |
| `Loopyard.MCP.ToolRouter` | Pure MCP `tools/list` + `tools/call` dispatch → `Loopyard.Tool.execute/2` |
| `LoopyardWeb.MCP.Server` | MCP-over-HTTP JSON-RPC plug (bearer-authed); `LoopyardWeb.MCP.Listener` is its dedicated `0.0.0.0` Bandit endpoint |
| `Aural.Channel` (`packages/aural`) | Per-channel ambient audio engine — synth + ffmpeg + PubSub fan-out. Lazy-spawned multi-tenant. See [packages/aural/README.md](packages/aural/README.md). |

## packages/

In-repo Mix packages extracted for reuse outside loopyard. Today's
only inhabitant is `:aural` — the cerebral audio bed feeding
`/aural` here and on the marketing site (loopyard.ai). Loopyard
pulls it via `path: "packages/aural"`; the marketing site pulls
via `git+sparse:` so it doesn't need a sibling checkout. New
extractions go here when something starts pulling its weight as
its own thing.

## Stack

Elixir 1.19 / OTP 28, Phoenix 1.7 / LiveView 1.1, Claude Code SDK (`claude_code`), Docker Compose, Tailwind CSS, xterm.js, Bandit. No database (ETS + GenServers).

## Architecture: Scaling & Persistence

**Workspace affinity model:** One workspace runs entirely on one node. Projects can span multiple nodes (different workspaces on different nodes), but a single workspace is always local to its node. This enables local storage without shared databases.

**Agent persistence:** Agents and messages are persisted to an append-only ETF log at `.loopyard/workspace/agents.log`. On server restart:
1. ServiceManager detects running containers via `Compose.ps`
2. Calls `replay_agent_log` to restore agent state to ETS
3. Starts ChatAgent GenServers with `resume: true` for each restored agent
4. Each agent loads its messages from ETS and starts a fresh Claude session

ETS remains the runtime store for fast multiplayer access; the log is the durable backing store.

**Message storage:** Messages are stored as a reversed list internally for O(1) append. `append_message` returns `{state, msg}` — the msg has its ID assigned. `summary/1` reverses before exposing to readers. Capped at 1000 messages in memory; the ETF log retains the full history.

**Log format:** Length-prefixed binary records using `:erlang.term_to_binary`. Events: `{:agent, id, data}`, `{:msg, agent_id, msg}`, `{:msg_update, agent_id, msg_id, changes}`.

## Known issues

- Agent log compaction not implemented (append-only log grows, replay gets slower over time)
