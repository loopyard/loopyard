# Code Rules

These rules exist because we learned them the hard way. Each one prevented a real bug. If you break one, you will ship a bug that wastes hours to debug.

## Every feature needs tests — no exceptions

Write a failing test first, then implement. Not optional. See [TESTING.md](TESTING.md).

If you're fixing a bug, write a test that reproduces it BEFORE writing the fix. Run the test, watch it fail, then fix the code, then watch it pass. If you skip this, you have no proof the fix works. We've shipped "fixes" multiple times that didn't actually fix anything because the test wasn't written first.

## UI rhythm — group by proximity, share gutters

Before writing Tailwind spacing on any multi-item layout (sidebars, chat cards,
option lists, panels), **load the `ui-rhythm` skill** (`.claude/skills/ui-rhythm`).
The recurring bug: within-group and between-group spacing come out the same, so
nothing reads as a group — it happened in the sidebars and the question card.
The rule in one line: **between-group gap must be ≥4× the within-group gap**
(the `SideNav` exemplar runs ~16×: `space-y-px` within, `pt-4` between), the
between-group gap comes from ONE side (never `mb-*` on A + `pt-*` on B), and every
text element shares one left gutter via consistent horizontal padding. Exemplar:
`lib/loopyard_web/components/side_nav.ex`.

## Isolate logic into testable modules

Don't bury behavior in LiveView private functions. If it has logic worth getting right, it belongs in its own module with its own tests. LiveViews should be thin — they handle events, delegate to modules, and render.

**~300 lines is the soft ceiling.** If a module is growing past that, ask: is this multiple concerns, or one tight concern with its own vocabulary?

*Split* when the functions cluster into groups that don't share state in interesting ways — each cluster has its own vocabulary and a reader can understand one without loading the other.

*Don't split* when the module is **proximate complexity**: a single GenServer where state transitions are interleaved, a LiveView multiplexing over many routes against one subscription set. Splitting those spreads one state machine across files and makes every reader chase callbacks. Prefer section-header comments there.

Historical wins (real concerns, not just size):
- `container.ex` (1500 lines, 20 tools) → 22 files, one per tool. Each tool was independent — clear win.
- `project_registry.ex` → `ProjectRegistry` + `WorkspaceRegistry`. Different lifecycles, different callers.
- `volume_manager.ex` → `VolumeManager` + `VolumeIO` + `VolumeCloner`. Different boundaries (CLI / file I/O / clone pipeline).

Current files over 300 that stay whole on purpose. Their sizes are ENFORCED,
not hand-maintained here: `test/loopyard/invariants_test.exs` caps every file
at `@default_max_lines` (800) and carries a per-file allowance list
(`@size_allowlist`) for the known-large ones — when you split one, lower or
remove its allowance; never raise a cap to make a file fit.
- `workspace_live.ex`. The workspace view multiplexes chat + file browser + git viewer + volumes + services against one PubSub subscription set. The **render pipeline and shared live data are the concern** — splitting into per-tool LiveViews loses multiplayer cohesion (see docs/ARCHITECTURE.md § LiveView architecture). Handler clusters with their own vocabulary (`DiffLoader`, `FileBrowser`) ARE extracted. The remaining size is genuine multiplexing, not mixed concerns.
- `chat_agent.ex`. One GenServer per agent session. Send/stop/restart/stream transitions are interleaved — extracting them would thread the same state across files. Section-header comments navigate by concern; OS-process and state-machine helpers are extracted as separate modules.
- `compose.ex`. One subject (Docker Compose lifecycle + validation). No internal vocabulary split.

Rule of thumb the next time this comes up: **can a reader understand half this file without reading the other half?** If yes, split. If no, section-header it.

**LiveView extraction pattern:** extract into modules under `live/workspace_live/`. Each module exports functions that take and return sockets. The LiveView's handlers become one-line delegates:
- `WorkspaceLive.Components` (use macro that imports Sidebar, Chat, Services, Volumes, SyncDetail, ContextPanel, States, Formatters, SetupProgress — the module's `__using__/1` is the list)
- `WorkspaceLive.AgentLifecycle` — spawn, select, list agents
- `WorkspaceLive.ServiceLogs` — fetch, refresh, format service logs
- `WorkspaceLive.DiffLoader` — git diff / commit fetches (adapter-scoped)
- `WorkspaceLive.FileBrowser` — volume file browser (tree + probe_path)

**Examples of what to extract:**
- `StreamBuffer` — streaming accumulation logic. 31 unit tests.
- `Terminal.build_cmd/1` — command construction testable without Docker.
- Pure formatters (`time_ago`, `exit_reason`, `service_status_text`) → `Components.Formatters`

**The pattern:** if you find yourself writing complex logic inside `defp` in a LiveView, stop. Extract it. Test it. Wire the LiveView to call it.

## Every Docker shell-out honours the daemon gate

`Docker.docker/2`, `stream/3` and `open_port/2` refuse to spawn the CLI when
`:docker_enabled` is false (the default test suite). Anything that reaches
for `System.shell`/`System.cmd`/`Port.open` with `docker` on its own MUST
check `Docker.daemon_available?()` first and degrade to a no-op or
`{:error, :docker_disabled}`. `VolumeIO.mirror_dir` didn't (Sept 2026): every
agent boot in the suite spawned the real CLI — ~230 ms per test, a third of
the whole run — and `docker run -v <name>` auto-created a volume per test
workspace. A bypass is invisible in CI (Docker is off there) and only shows
as "the suite is slow".

The one named exception is the daemon probe itself: `DockerDaemon.probe/0`
(`docker_daemon.ex`) shells `docker version` directly, by design — it is what
DECIDES whether the daemon is up, so it cannot sit behind the gate it feeds.
Its test seam is the `:docker_probe_fun` app config, not `:docker_enabled`.

## Keep tests fast

Unit tests should run in under 2 seconds total. If a test needs Docker, external services, or takes >1 second, tag it with `@tag :docker` or `@tag :slow` and exclude from default runs. Run full suite in CI.

**Example:** `AgentLog` tests run in 0.1s because they use temp files and injected ETS tables, not real workspaces.

## Test macro-generated schemas are serializable

If a macro generates data that will be JSON-encoded at runtime (tool schemas, MCP protocol messages, API responses), write a test that encodes it. The `tools/list` crash taught us this: a `~s|...|` sigil in a tool param description survived compilation as an AST tuple, crashed `Jason.encode!` at runtime, and created a hot restart loop.

```elixir
test "every tool schema is JSON-serializable" do
  for tool_mod <- Container.__tool_server__().tools do
    tool_def = %{"name" => tool_mod.__tool_name__(), "inputSchema" => tool_mod.input_schema()}
    assert {:ok, _} = Jason.encode(tool_def), "#{tool_mod} not serializable"
  end
end
```

This test catches the entire class of "macro stored AST instead of evaluated value" bugs.

## Test the real path, not a mock of it

If users hit a bug through the websocket → channel → GenServer → Port stack, the test must exercise that same stack. A unit test that passes on an isolated layer while the integration is broken is worse than no test — it gives false confidence.

**We learned this the hard way:** Terminal unit tests passed (PTY echo was fine in isolation) while users saw double-echo in the browser. The bug was a PubSub topic collision between the Terminal output topic and the Phoenix channel topic — only visible when the full websocket stack was exercised. We found it by writing `terminal_integration_test.exs` that connects via the channel, sends input, and asserts output appears exactly once.

Concretely:
- **Inject dependencies** so tests can substitute local processes for Docker containers (e.g. Terminal accepts a `cmd` option so tests use a local shell instead of `docker exec`)
- **Test multiplayer** — spin up N subscribers, have each send input, assert each sees output exactly once. This catches PubSub topic collisions, stale connection duplication, and buffer replay overlap.
- **Prove the bug exists before fixing it.** Write a test that fails, THEN fix the code, THEN confirm the test passes. Don't ship a fix you haven't verified through a failing→passing test cycle.
- **Don't test rendering alone** — render tests prove HTML structure but not behavior. Test the accumulation, dedup, windowing, and state restoration logic as units.

## All state mutations go through GenServers

Never write directly to ETS from outside the owning GenServer. Use `ChatAgent.append_message_ets/2` and `ChatAgent.update_message/3` which route through the GenServer via casts. Direct ETS writes get overwritten.

## Never modify shared state in assigns directly

If other viewers should see a change, it must go through GenServer → PubSub → all LiveViews. Never update `messages`, `agents`, `service_statuses`, or any shared data in socket assigns directly from a `handle_event`. Call the GenServer and let the PubSub broadcast update all viewers.

Local assigns are only for per-viewer UI state (which tab is active, whether a rename input is open).

**The bug this prevents:** we had optimistic local message adds — the sender's LiveView added the user message directly to assigns, and the PubSub handler skipped `:user` role messages to avoid duplication. Result: other viewers never saw what the user typed. The fix: remove all optimistic adds, let every message flow through PubSub.

## PubSub topics must not collide with channel topics

Phoenix's channel transport subscribes to the channel topic string internally. If your GenServer broadcasts on the SAME topic string, the transport receives both the raw broadcast AND the channel's push — doubling every message. Use distinct topic strings: `"terminal_output:#{id}"` for GenServer broadcasts vs `"terminal:#{id}"` for the channel topic.

## Multiplayer is the default, not a feature

Every new feature must work with multiple viewers. Before shipping:
1. Can two browser tabs see the same state?
2. If one tab makes a change, does the other tab update?
3. If someone joins late, do they see the current state?
4. If someone clears/resets, does everyone see it?

This applies to chat messages, terminal sessions, service statuses, build output — everything.

## No side effects in LiveView mount or handle_params

Mount is **read-only**. Never start services, create containers, or modify external state on mount.

## No boolean flag arguments — pass a list of what you want

When a function loads or does several things and the caller picks a subset, **never** model that with `do_thing: true/false` flags. Pass a list of atoms naming the slices you want and have the function dispatch on membership.

**Don't:**
```elixir
load_workspaces(project, include_services: true, include_volumes: false, include_agents: true)
```
This pattern multiplies: every new slice adds another flag, every call site has to know which flags exist, every flag combination is its own untested code path, and the function body fills up with `if include_x do ... else ... end` branches.

**Do:**
```elixir
load_workspaces(project, [:agents, :services])           # mount — fast
load_workspaces(project, [:agents, :services, :volumes]) # async refresh — full
```

The function dispatches per section (`if :services in sections do ...`), and adding a new slice means adding one new section handler — no flag, no call site updates.

Boolean arguments are a code smell in general. They make call sites unreadable (`foo(x, true, false, true)`), conflate "the thing exists" with "the thing is on", and they're almost always hiding two functions or a richer enum. Use them only when the parameter is genuinely binary in nature (`force?: true`, `dry_run?: true`) — and even then, prefer a keyword arg with a `?` suffix so the call site reads.

## Mount must render instantly — every slow slice gets its own `start_async`

Mount renders the page. It must not block on Docker, the filesystem, the network, or any other potentially-slow call. **The page must paint in <100ms**, with loading skeletons in place of any data that hasn't arrived yet. Slow data fills in via Phoenix LiveView's `start_async/3` and `handle_async/3`.

**Do NOT do this in mount:**
- `docker ps`, `docker inspect`, `docker compose ps`, `docker stats` — every shell-out is 100ms+; `docker stats --no-stream` alone takes 1-2s
- `ServiceStatus.for_workspace/1` — fans out into N `Docker.container_running?` calls
- `VolumeManager.list_workspace_volumes/1` — shells out to docker
- `File.read` / `File.exists?` on anything that might not be local
- Any function that walks all workspaces × all services in a synchronous loop
- A single "load everything" call that bundles fast and slow slices together — they MUST be independently fetchable

**Do this instead:**

```elixir
alias Phoenix.LiveView.AsyncResult

def mount(_params, _session, socket) do
  socket =
    socket
    |> assign(:host_cpu, AsyncResult.loading())
    |> assign(:host_memory, AsyncResult.loading())
    |> assign(:beam, SystemStats.beam_stats())   # pure VM lookup, instant — fine in mount

  if connected?(socket) do
    {:ok,
     socket
     |> start_async(:host_cpu, &SystemStats.host_cpu/0)        # one shell-out, runs in its own Task
     |> start_async(:host_memory, &SystemStats.host_memory/0)} # parallel with host_cpu
  else
    {:ok, socket}
  end
end

def handle_async(key, {:ok, value}, socket) do
  {:noreply, assign(socket, key, AsyncResult.ok(socket.assigns[key], value))}
end

def handle_async(key, {:exit, reason}, socket) do
  {:noreply, assign(socket, key, AsyncResult.failed(socket.assigns[key], reason))}
end
```

**Critical properties this gives you:**
- Mount returns in microseconds. The first paint is HTML with skeleton classes (`animate-pulse`).
- Each slow slice runs in its own `Task` — they're **parallel**, not serialized.
- A hung `docker stats` call doesn't block `host_cpu` or `host_memory`.
- A failed slice is contained: `AsyncResult.failed/2` lets the template show "failed to load" for just that card.
- Refresh = call `start_async/3` again; the LiveView updates that one assign in place.

**Test that mount actually stays fast.** Wrap `live(conn, "/the/page")` in `:timer.tc/1` and assert under 500ms. **Every LiveView with non-trivial data needs this test.** If a synchronous shell-out leaks back in, the test fails immediately:

```elixir
test "mount renders without blocking on docker" do
  {micros, {:ok, _view, _html}} = :timer.tc(fn -> live(conn, "/system") end)
  assert micros < 500_000, "mount took #{div(micros, 1000)}ms — sync slow call slipped in"
end
```

**The same rule applies to `handle_params`.** It runs on every URL change inside a live session. Patches between actions (`:index` ↔ `:chat` ↔ `:new`) hit handle_params, NOT mount. If you put a `Docker.container_running?` or a `VolumeManager.read_file` in handle_params, every navigation hangs. We've shipped this bug — the workspace landing page synchronously called `VolumeManager.read_file` (which is a docker exec/run) in `handle_params(:index)` to decide whether to redirect to `/new`. Fix: defer with `start_async/3`, store the decision-driving result in an assign, do the navigate from `handle_async/3`. The page paints instantly; the decision lands a tick later.

**Slice helpers must be independently callable.** Don't write `SystemStats.everything()` and pretend you'll only call it from refresh paths — someone will call it from mount and the page will hang. Each slice is its own public function (`host_cpu/0`, `host_memory/0`, `docker_container_stats/0`, …), and the module's docstring should say "every public function is one slice, never bundle them".

**Same rule for `handle_params`** — it runs on every URL change. Never put a Docker call there.

**`send(self(), :fetch_thing)` + `handle_info` is the older pattern — still acceptable for in-VM work that's borderline-cheap, but for real shell-outs use `start_async`. The two reasons: (1) `start_async` runs the work in a separate process so it doesn't block message processing on the LiveView; (2) `AsyncResult` gives you loading/ok/failed states for free in the template.

## Drill-down pages don't duplicate scoped pages

When a domain has both a global "cluster oversight" view and a per-thing "this one item" view, **they are different pages with different responsibilities** — don't smush them together and don't reimplement one inside the other.

| Page | Responsibility |
|------|---------------|
| `/projects/:id` | Project-scoped: workspaces, agents, services FOR THIS PROJECT. Where the user goes to *use* the project. |
| `/system/workspaces` | Cluster-wide: every workspace's supervisor health. Where the user goes when something is broken and they want to restart. |
| `/system/workspaces/:id` (if added) | One workspace's deep diagnostic view (containers, agents, processes, recent errors). |
| `/system/docker` | Cluster-wide Docker state (every `loopyard-*` container, every volume). Where the user goes for cluster-wide cleanup. |

**Rules:**
1. If a behavior already exists on the scoped page, the system page links to it. Don't reimplement "click an agent to chat with it" on `/system/workspaces` — that's what `/projects/:id/workspaces/:id/agents/:id` is for.
2. System pages are for **diagnosis and remote fixing** — restart, kill, rm -f, prune. Scoped pages are for **using** the thing.
3. Each page does its own slice loading. Don't share a "load everything" function between them.
4. Top-level system overview (`/system`) is intentionally thin: host stats, BEAM totals, counts, recent errors, links into the deeper pages. It must fit in one screen and load instantly.

## Display formatters and tiny UI primitives live in shared modules — never `defp`'d in a LiveView

If a function would be `defp shorten_path/1` or `defp format_bytes/1` or `defp project_location/1` in a LiveView, **stop**. Put it in `LoopyardWeb.Format` instead. The `html_helpers/0` macro auto-imports `LoopyardWeb.Format` into every LiveView, component, and HTML module — these helpers are available everywhere by default.

Same rule for tiny render primitives that show up in 2+ LiveViews:

| Pattern | Lives in | Use |
|---|---|---|
| Flash strip (`@flash["error"]` / `@flash["info"]`) | `LoopyardWeb.Components.Common` | `<.flash_banner flash={@flash} kind={:error} />` |
| Loading skeleton (`animate-pulse`) | `LoopyardWeb.Components.Common` | `<.skeleton />` or `<.skeleton variant={:card} />` or `<.skeleton rows={4} />` |
| Page header / breadcrumbs | `LoopyardWeb.Components.AppHeader` | `<.header breadcrumbs={[{"Loopyard", "/"}, ...]} iex_session={@iex_session} />` |
| Sidebar bits (status/service dots, agent items) | `LoopyardWeb.Components.Sidebar` | imported on demand |
| Log content panels | `LoopyardWeb.Components.LogViewer` | imported on demand |
| Path → "~/foo", byte/number formatting | `LoopyardWeb.Format` | auto-imported |

`Format` and `Components.Common` are the only two things that get **auto-imported** via `html_helpers/0` — they're the absolute basics every page needs. Bigger components (sidebar, log_viewer) are imported on demand by the LiveViews that use them, so we don't pollute every render with stuff most pages don't need.

**Anti-pattern that bit us:** `shorten_path/1` was `defp`'d in 4 different files (`chat_live`, `project_live`, `project_list_live`, `tool_summary`) — each implementation drifted slightly. The flash banner HTML was copy-pasted into 4 LiveViews with identical Tailwind classes. Loading skeletons were re-rolled in 2 system pages. All of those went away when we centralized them.

**The test for "is this duplicated?":** if you're about to type the same 5+ lines of code (or HTML) you've already typed in another file in this session, stop. Extract it. The cost of one new module is far less than the cost of three slightly-different copies that drift over months.

## Views observe, infrastructure acts

Views read from ETS/GenServers. They never create or modify infrastructure state. Infrastructure modules never depend on web modules.

## Containers persist across server reboots

`ServiceManager.terminate` does NOT call `compose down`. On restart, `init` detects running containers via `Compose.ps` and reconnects. Containers come down only through the explicit teardown paths: `Compose.down/2` via `ServiceManager.stop_services/1` (the user's stop action), `Onboarding.stop_preview/1`, and `Workspace.Destructor` (workspace deletion). There is no `/system/reset` route.

## Message URL rules

- Real `<a href>` with `target="_blank" rel="noopener"`. No JS hacks.
- EVERY broadcast must include the message `:id`. `append_message` returns `{state, msg}` — broadcast the returned `msg`, never `List.last(state.messages)`.
- No tokens — simple URLs: `/messages/:agent_id/:msg_id`

## Streaming sync

Use `StreamBuffer` for all "show existing content + stream new data" patterns. It handles rolling byte windows, message upsert, and page-reload restoration. Don't reinvent this in LiveView assigns.

## Never publish streaming deltas per token

Raw token deltas arrive 30–60×/s. Publishing each one makes every connected
LiveView re-ship and morphdom-patch the entire accumulated text per token —
the browser main thread saturates and typing lags for everyone watching.
Delta events queue on `state.stream_pub_buffer` in the ChatAgent and flush
as one combined publish per 100ms tick (`StreamHandler.flush_stream_deltas/1`).
A new delta-shaped event goes through `buffer_stream_delta/3`, never straight
to `Events.ChatAgentMessage.publish/1`; every turn-reset/interrupt path must
drop the buffer (`drop_stream_deltas/1`) so a late flush can't ghost a stale
streaming bubble.

The same rule covers BUILD OUTPUT: port chunks from exec/docker_compose
stream through `Helpers.drain_port_burst/3` (one update + one broadcast per
~100ms burst). Per-line publishes from a watcher measured as 175ms
main-thread stalls while typing; batched, the same load is a 32ms blip.

## The client is a scarce resource — run on the server by default

Treat the browser, the DOM, and client-side JS as scarce. **Don't compromise
functionality — but do as much on the server as makes sense, and reach for JS
only when the server genuinely can't do the job well.** State and logic live
server-side (assigns, PubSub, GenServers); the client renders what the server
sends. This is why the whole app is server-driven — it keeps the client thin,
multiplayer-consistent, and fast, and it keeps behavior testable in Elixir
instead of hidden in browser state.

**The narrow, legitimate exception is per-frame *presentation* the server
shouldn't drive** — a ticking clock, a CSS transition. A server tick would push
a socket diff to every connected browser *every second* just to animate a
number; that's the wrong trade. So a live timer runs in a tiny hook — but the
**state still comes from the server** (a timestamp assign); the hook holds none,
it only animates the display *between* server updates. The `Elapsed` hook is the
model: ONE hook counts both up (`data-since`) and down (`data-until`), server
owns the timestamp. If a new need looks like an existing hook, **generalize the
hook — never add a near-duplicate.** JS bloat is a cost you pay on every page
load and every interaction; spend it deliberately.

Before adding client JS, ask: can an assign + PubSub do this? Can an existing
hook be generalized? Is this truly per-frame presentation, or am I about to put
*state* in the browser? Only the last, presentation-only case earns new JS.

## Operations must be idempotent

Check if running before starting. Never `docker rm -f` then `docker run` unconditionally.

## Everything through Dockerfiles, never runtime scripts

Never `docker exec apt-get`. It doesn't persist across container restarts.

## Auto-restart dead CLI sessions

ChatAgent checks `session_alive?` before every send. Restarts with exponential backoff (2s, 4s, 8s, 16s, 32s). After 5 consecutive crashes, gives up and marks the agent `:crashed` — the user must fix the underlying issue. Counter resets on successful `stream_done`. No auto-replay of user messages (causes crash loops).

**The bug this prevents:** a `tools/list` serialization bug (unevaluated sigil in a tool description) caused every session to crash on startup. Without backoff, the agent hot-looped restarts and hammered the Claude API until rate-limited.

## Resource cleanup goes through remove_project

When tearing down a project (eval cleanup, user deletion, system reset), always call `ProjectRegistry.remove_project/1`. It dispatches through the Source adapter to clean up adapter-specific resources (Local: mutagen session, host worktree, volumes; GitHub: volumes). Never write ad-hoc cleanup that manually stops workspaces, deletes volumes, or wipes agent logs — if `remove_project` doesn't handle it, fix `remove_project`.

**The bug this prevents:** the eval runner had 50 lines of inline cleanup code that duplicated `remove_project` but missed edge cases, leaking 700+ Docker volumes over a weekend.

## Docker volume naming must be canonical

Volume names are **always** `<prefix><workspace_id>-code`, produced by `VolumeManager.code_volume_name/1` — the single source of truth. The prefix is `Docker.prefix/0` (`:resource_prefix` app config, `loopyard-` by default; the test suite runs under its own prefix so it can never name a real resource). Never create volumes with other naming conventions (the old `code-<workspace_id>` pattern created ghost volumes that never got cleaned up), and never spell the prefix out by hand. `Workspace.volume_name_for/1` looks up the workspace's registered volume, falling back to `code_volume_name` — never to an ad-hoc format.

## Never silently swallow errors in cleanup

```elixir
# BAD — hides why volumes leak
rescue _ -> :ok

# GOOD — cleanup continues but you can diagnose failures
rescue e -> Logger.warning("[Module] cleanup failed: #{Exception.message(e)}")
```

This rule is about RESOURCE-CLEANUP paths — volume/container/session release,
`terminate/2`, janitor release fns — where a swallowed error is a leak nobody
can diagnose. A bare `_ -> :ok` rescue elsewhere (a best-effort telemetry or
EventLog call, an optional ETS read inside a probe) is fine when the failure
changes nothing you would act on; ~20 such sites exist on purpose. The test:
if this rescue fires and a resource is left behind, it needs the log line.

## Every Task must be supervised

Never `Task.start(fn -> ... end)`. Always `Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn -> ... end)`. Unsupervised tasks crash silently — nobody notices, nothing retries, the work just disappears. `Task.start_link` is acceptable only when the parent GenServer needs to detect the crash (e.g., ChatAgent's streaming task).

## New fields go in normalize, not in fallback chains

When you add a field to a workspace (or project), pre-existing records in ETS won't have it. Don't scatter fallback logic across consumers — add the backfill to the private `WorkspaceRegistry.normalize_workspace/1` (or the project equivalent). That function runs on every ETS read and is the single place for "if this field is missing, here's how to compute it."

**The bug this prevents:** `worktree_path` was added but pre-refactor workspaces had `nil`. WorkspaceGroup, SyncMonitor, and Source.Local each wrote their own fallback to compute it — three different implementations that drifted. The fix: one backfill rule in `normalize_workspace`, zero fallbacks anywhere else.

## ETS tables are owned by StateKeeper

Never create ETS tables from random modules. All named tables are defined in `StateKeeper.@tables` and created in `StateKeeper.init/1`. No `ensure_ets_table` pattern — if the table doesn't exist, something is deeply wrong and should crash loudly. `StateKeeper.ensure_tables!/0` exists only for test setup.

## Never block a LiveView on Docker

Any Docker call (shell-out, container inspect, log fetch) takes 100ms+. Never call these synchronously in `handle_info`, `handle_event`, or `handle_params`. Use `Task.Supervisor.start_child` + `send(self(), {:result, data})` or `start_async/3`. The LiveView process must stay responsive to PubSub messages and user events.

For container/volume state that LiveViews need on every render, use `Docker.Observer` — it maintains an ETS cache updated by `docker events` stream. Zero Docker calls from LiveViews for status data.

## MCP tools are one module per tool

Each tool lives in its own file under `lib/loopyard/tools/container/`. No monolithic tool files with 20 tools crammed together.

**Tool module structure:**
```elixir
defmodule Loopyard.Tools.Container.Exec do
  use Loopyard.Tool,
    name: "exec",
    description: "Run a shell command inside the container.",
    params: [
      agent_id: {:string, required: true},
      command: {:string, required: true},
      timeout: {:integer, description: "Max seconds (default: 120)"}
    ]

  def execute(%{agent_id: id, command: cmd} = params, _assigns) do
    # tool logic — the ONLY function you write
  end
end
```

The `Loopyard.Tool` macro generates `__tool_name__/0`, `__description__/0`, and `input_schema/0`. You just write `execute/2`. Params arrive with atom keys (SDK atomizes them).

The toolkit module (`Loopyard.Tools.Container`) lists all tool modules in `__tool_server__/0`. Server name `"loopyard-container"` must not change (agent prompts reference it).

**No `do_` prefix.** The main function is `execute/2`. If a tool needs private helpers, name them descriptively — `apply_edit`, `format_probe_result`, etc.

Shared helpers live in `Loopyard.Tools.Container.Helpers` — resolve_container, validate_workspace_path, etc.

## Validate inputs at tool boundaries

Every MCP tool validates its inputs before doing work:
- **Paths**: `Helpers.validate_workspace_path/1` — rejects traversal, absolute paths outside /workspace, null bytes
- **Strings**: `Helpers.validate_string(value, field, max_bytes)` — rejects non-strings, oversized inputs, null bytes
- **Timeouts**: `Helpers.validate_timeout/1` — must be 1-3600 seconds

Use `with` chains at the top of `execute/2` to bail early on bad input.

## Never `String.to_atom` on values you don't fully control

Atoms are not garbage-collected. Calling `String.to_atom` on input from JSON, HTTP bodies, agent output, or anything an attacker (or a misbehaving agent) can influence is an atom-table DoS waiting to happen — the BEAM caps at ~1M atoms, then crashes.

Use `String.to_existing_atom/1` when you're mapping a string to a known set of atoms, or keep the value as a string and dispatch on it.

The current internal uses are bounded — the input space is fixed and operator-controlled: the cookie file read by `mix loopyard.rpc`, `mix loopyard.server` and `mix loopyard.harness_check`, the `project_store.ex` config keys, and the closed `@phases` set interpolated into an atom in `workspace/setup.ex`. Credo's `Credo.Check.Warning.UnsafeToAtom` (`.credo.exs`) now guards this: each allowed site carries a `credo:disable-for-next-line` / `credo:disable-for-this-file` comment with its reason, and a new `String.to_atom` without one fails `mix credo`. If you extend the project store, source config, or any other deserializer to accept new keys, switch the conversion to `String.to_existing_atom/1` or keep keys as strings.

## `Phoenix.HTML.raw/1` only with proven-safe HTML

`raw/1` skips Phoenix's auto-escaping. The bytes it receives land verbatim in the browser. Every call must satisfy one of:

1. **Escape-then-mutate.** Input is run through `Phoenix.HTML.html_escape/1` first, then a transformation that only inserts known-safe markup (e.g. `Components.Ansi.to_html/1` escapes the text and only adds `<span class="...">` tags around it).
2. **Trusted producer.** The HTML came from a library whose contract is "I emit safe HTML" (Makeup syntax highlighting, `Loopyard.Markdown.to_html/1` — MDEx with `unsafe_: false`, which escapes any raw HTML in the source; that option IS the boundary, never flip it — and server-controlled SVGs like the QR code in `connect_live.ex`).
3. **Static literal.** A fixed string in the call site (`Phoenix.HTML.raw("&nbsp;")`).

Never pass agent output, chat messages, filenames, log lines, terminal output, or anything a remote source produced directly into `raw/1`. If you need to render formatted agent content, escape first and add markup on top.

## Don't `assign_new` for values that must refresh

`assign_new/3` only sets the assign if it's missing — but on LiveView reconnect after a network blip, the parent assigns from the disconnected mount can still be present, and `assign_new` silently skips. The page renders with stale data and looks "fine" until the user clicks something.

Use `assign_new` only for values that genuinely never change for the lifetime of the LiveView (current user, route param echo). For anything that could be stale across a reconnect — service status, agent state, file contents, anything observed from a GenServer or ETS — use `assign/3` so the reconnected mount overwrites the stale value.

## Emit telemetry on key operations

Wrap slow or important operations in `:telemetry.span/3`:
- `Docker.docker/2` emits `[:loopyard, :docker, :command]`
- `Compose.up/2` and `down/2` emit `[:loopyard, :compose, :up/:down]`
- `ChatAgent` emits `[:loopyard, :agent, :message]` on user messages

Don't add telemetry subscribers — that's for the operator to configure. Just emit the events.

## Keep it simple

Don't add infrastructure users have to install, configure, or manage. If a feature requires `sudo`, system packages, or manual setup steps, it's too complex. The app should work out of the box with `mix loopyard.setup && mix loopyard.server`.

Don't add toggles for things that should just be on. Don't add config files for things that have sensible defaults. Don't add "advanced" sections that hide complexity — either the feature is simple enough to be always-on, or it's not ready.

## One source of truth per domain

Each piece of data should have exactly ONE authoritative source. If you find yourself reading the same information from multiple places, you've created drift.

**Sources of truth:**
- **What services SHOULD exist** → `docker-compose.yml` via `ServiceStatus.list_defined_services/1`
- **What services ARE running** → Docker via `Docker.container_running?/1`
- **Compose file path** → `Compose.compose_path/1` (never hardcode `.loopyard/workspace/docker-compose.yml`)
- **Workspace ID** → `Workspace.workspace_id/1`
- **Project name prefix** → `Compose.project_name/1`

**Anti-patterns we've had:**
- `workspace.json` describing services AND `docker-compose.yml` describing services → agents didn't know which to use
- `ServiceManager.service_status/1` AND `ServiceStatus.for_workspace/1` → callers picked randomly
- Direct `docker ps` calls scattered across modules instead of going through `ServiceStatus`

If you need service information, use `ServiceStatus.for_workspace/1`. It reads from `docker-compose.yml` and merges running state from Docker. Don't reinvent this.

## Agents write infrastructure directly — no intermediate config

Agents write `Dockerfile` and `docker-compose.yml` directly to `.loopyard/workspace/`. They do NOT use intermediate config files like `workspace.json`. The compose file IS the config.

**Correct flow:**
1. Agent reads codebase to understand the stack
2. Agent writes `Dockerfile` via `write_file`
3. Agent writes `docker-compose.yml` via `write_file`
4. Agent runs `docker_compose up -d --build`

**Wrong flow (legacy, avoid):**
1. Agent calls `set_dockerfile` tool → writes to `workspace.json`
2. Agent calls `add_service` tool → writes to `workspace.json`
3. Agent calls `rebuild` → generates `docker-compose.yml` FROM `workspace.json`

The second flow has an unnecessary layer. The `workspace.json` config was designed before agents could write files directly. Now they can. Use the direct path.

**Exception:** `set_workspace_name` and `set_system_prompt` tools write to `workspace.json` because they're metadata about the project, not infrastructure.

## Use canonical helper functions

When a pattern exists, use it. Don't write your own version.

| Need | Use | Don't |
|------|-----|-------|
| Compose file path | `Compose.compose_path(project_dir)` | `Path.join([dir, ".loopyard", "workspace", "docker-compose.yml"])` |
| Any docker command | `Docker.docker(args)` | `System.cmd("docker", args)` |
| Streaming docker | `Docker.stream(args, callback)` | `Port.open + System.find_executable("docker")` |
| Container running? | `Docker.container_running?(name)` | `System.cmd("docker", ["inspect", ...])` |
| Container ports | `Docker.container_ports(name)` | `System.cmd("docker", ["port", ...])` |
| Service list | `ServiceStatus.for_workspace(path)` | `System.cmd("docker", ["ps", ...])` + parsing |
| Container/volume state | `Docker.Observer.containers()` / `.volumes()` | `docker ps` from LiveViews |
| Project name | `Compose.project_name(workspace_id)` | `"loopyard-#{workspace_id}"` hardcoded |
| Registry lookup | `RegistryHelper.whereis/call/cast` | `case Registry.lookup(...) do [{pid, _}] -> ...` |
| Read file from volume | `VolumeIO.read_file(vol, path)` | `Docker.exec_in(container, "cat ...")` |
| Write file to volume | `VolumeIO.write_file(vol, path, content)` | Rolling your own base64 + docker exec |
| Clone repo into volume | `VolumeCloner.clone_into_volume(vol, url)` | Inline git clone + docker run |

**Every Docker CLI call goes through `Loopyard.Docker`.** No `System.cmd("docker", ...)` anywhere else — the one exception is the `DockerDaemon` liveness probe (see "Every Docker shell-out honours the daemon gate"). Docker.docker/2 handles timeouts, telemetry, and error formatting. Docker.stream/3 handles long-running commands with callbacks. Docker.open_port/1 handles raw port needs (Observer events, terminal).

## URL variants go in the path, never in a query string

When a single resource has multiple representations (formats, transports, codecs), model each one as a **sibling path with an extension or sub-segment**. Never as a `?format=` query param.

Good:
- `GET /aural/:id/stream.mp3`
- `POST /aural/:id/stream.whep` (future WebRTC transport)
- `GET /messages/:id/raw`
- `GET /branding/logo.svg`, `/branding/logo.png` (external site, served from `packages/brand`)

Bad:
- `GET /aural/:id/stream?format=mp3`
- `GET /messages/:id?format=raw`

Path-based variants read as "the resource in this format," cache better (different URLs → independent cache entries), and are cleaner to copy/share/curl. Reserve query strings for actual query parameters — filters, pagination, search.

## Tool results pair with tool calls by `tool_id`, never by position

Agents call tools in PARALLEL: the harness emits every `%{role: :tool}`
message first, then every `%{role: :tool_result}` — so "the nearest tool
message above me" attributes the FIRST result to the LAST call. That bug
rendered an `ls` dump as a syntax-highlighted "ruby" file card titled with
the path of a totally different `Read` call.

StreamHandler stamps the harness's `toolCallId` as `tool_id` on both the
`:tool` and `:tool_result` messages; the UI pairs with
`ToolResults.matching_tool_call/1` (id match, with an order-of-arrival
fallback for messages persisted before `tool_id` existed). Any new code
that needs "which call produced this result" goes through that helper —
never walk the message list positionally.


## Design system (hard-won, enforced by design_system_test.exs)

- **Derive shape from data; never compose position/shape across siblings.**
  The active-turn rail and grouped band corners both died of this: three
  elements that had to stay pixel-aligned across breakpoints. If a visual
  needs N elements to agree, redesign it to need one.
- **One job per color** (packages/brand/README.md): flame (orange) means
  blocked-on-a-human and nothing else; amber is transitional caution; never
  interchange them. Iris is the violet family — the indigo experiment is
  reverted and guarded.
- **Text uses the five-token scale** — `text-meta` / `text-body` / `text-lead` /
  `text-title` / `text-hero`, px values in CSS custom properties at the top of
  `assets/tailwind.config.js` so the whole scale shifts at one breakpoint.
  Tailwind's default sizes are REPLACED (`text-sm` generates nothing), and the
  chat's old private tokens (`chat-body`/`chat-sub`/`chat-meta`) are BANNED
  along with `text-lg`/`text-base` and arbitrary `text-[…]` values
  (`design_system_test.exs`, "the type scale is five tokens"). "Slightly
  different sizes" is how the stream turned into a jumble twice.
- **Hooks on phx-update="ignore" DOM must wire-once** (element persists across
  LiveView reconnects; mounted() re-runs → duplicated listeners). Guard with
  `el.dataset.wired`.
- **Sends are optimistic** — never gate visible feedback on a LiveView ack
  (the LV can be seconds behind on a busy stream). Clear/echo instantly,
  reconcile on ack, restore on failure.
- **Never run `mix compile`/`mix test` (dev env) against the live checkout** —
  the dev server shares it; verify via curl. `MIX_ENV=test mix test <file>` is
  OK (separate build dir), one suite at a time.

## URLs are resources, never query-string soup

Every addressable thing gets a PATH, mirroring the existing grammar
(`/projects/:project_id/workspaces/:workspace_id/...`,
`/messages/:agent_id/:msg_id`, `/notifications/:agent_id/:msg_id`). Query strings are
for OPTIONS on a resource (filters, legacy fallbacks), never for identity.
Before adding a `?thing=id` param, add the route. A URL should read like it
means something when pasted into a chat — that's the test.

## In-between states are two-tiered (multiplayer!)

Between "the user acted" and "processed" there are TWO windows with different
owners:

1. **Click → server receipt** (ms): the ONLY legitimately client-side feedback
   — the server can't broadcast what it hasn't received, and only the clicker
   needs it. Floor: the global `.phx-click-loading`/`.phx-submit-loading`
   styles (app.css). The composer's instant clear + #send-echo is the same
   tier, richer.
2. **Server receipt → processed**: MULTIPLAYER. The transitional state must be
   SERVER state, broadcast, so every viewer sees "being worked" — a status
   transient on the card (`:creating`/`:integrating`/`:deleting` via
   `update_message`), the pending queue, drafted selections. Never model this
   tier client-side: the other people in the room would see a frozen UI.

When adding an input, ask BOTH: what does the clicker see at 200ms, and what
does everyone ELSE see while it processes? "Nothing changed" is a bug in
either seat.


## Safe-area insets: the page shell owns them, once

`safe-area-top` (and `safe-area-x`) belong on the OUTERMOST page shell —
exactly one application per page. Components, nav bars, and wrappers must
never add them: a bar applying its own inset on a page whose shell already
has one stacks a ~2× dead band at the top of the installed PWA. Enforced by
`design_system_test.exs` ("safe-area-top lives on page shells ONLY"); adding
a new page shell means adding its file to that allowlist deliberately. The
`#conn-banner` overlay uses `safe-pt` (fixed-position, separate concern).

## Inner scrollers with sticky children are `isolate`

A scroller (`overflow-y-auto`) is not a stacking context, so a `sticky …
z-10` band inside it (the chat's prompt band, a decision's collapsed card)
competes with `.app-bar` in the ROOT context. Chrome wins by z-index on
paper — but during an iOS rubber-band WebKit composites the overscrolled
content and painted it OVER the bar (the purple turn card popped above
"Operator"; a decision's byline shoved the back arrow). Put `isolate` on the
scroller: nothing inside can then outrank the chrome, whatever the
compositor does. `#messages` and each decision slide's scroller carry it,
plus `overscroll-y-contain` (no chaining into the page — the bounce itself
STAYS; the rubber band is part of the feel and is never the fix). Do NOT
`transform-gpu` the bars: a composited sticky bar smeared a translucent band
across the iOS status-bar region.

## App-shell pages lock the document

A page with fixed chrome and scrolling panels (the Operator shell) is
`h-dvh` (the VISIBLE viewport — on iOS 100vh is the toolbar-hidden height,
so `h-screen` left the page taller than the screen) and carries
`data-app-shell`, which sets `html, body { overflow: hidden; overscroll-
behavior: none }`. A pull at a panel's top then has nothing to chain into;
the bars cannot be dragged off. Only the panels scroll.

Today only the Operator shell (`Components.AppShell`) does this.
`workspace_live.ex` still renders `h-screen` WITHOUT `data-app-shell` — that
is the pending migration, not a pattern to copy; a new shell follows
`AppShell`.

## The inbox: raise through the funnels, never scan

Every decision card (question / approval / secret request) is appended via
`ChatAgent.MessageWindow.append_message_ets/2` and its status flipped via
`update_message_now/3`. Those two calls are what tell `Loopyard.Notifications`
an item was raised or settled. A new card kind or a new way to settle one
MUST go through them — a card written to ETS any other way is invisible to
the inbox until the reconcile sweep catches it (up to 60 s), and a status
flipped any other way leaves a phantom open item for as long. Never compute
"what's waiting on a human" by scanning agent summaries; read the store
(`Notifications.open/1`, `Attention.line/1`). It used to be a scan on every
render of four surfaces and inside every push payload. The surfaces that read
it are `/notifications` (canonical) and its `/decisions*` / `/review*` aliases
(`router.ex`) — there is no `/queue`. Known wart: `Attention.line/1` accepts a
`host` argument it ignores (`def line(_host \\ nil)`) while `dashboard_live`
and `operator_live` still pass one; it is call-site compatibility, not a
contract — don't build on it.
