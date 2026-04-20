# LiveView flapping audit — April 2026

Two user-reported flashes in the workspace sidebar, both traced to
`<.link navigate>` and render-time `Registry.lookup/2`. This doc
captures what we found, what we changed, and what stayed put.

## The bugs

1. **"Starting…" pill vanishes on sidebar click.**
   User clicks the Start button → `workspace_state` transitions to
   `:starting` → pill reads "Starting…" → user clicks a service /
   volume / sync sidebar item → pill flips back to "Stopped" even
   though compose up is still in flight.

2. **Agent row flashes "Sleeping" on sidebar click.**
   Currently-selected agent's sidebar dot + label briefly render
   as "Sleeping" when the user clicks *any* sidebar item, then
   settles back to "Ready." The agent GenServer is alive the
   whole time.

## Root causes

### Bug #1 — `push_navigate` between same-module routes remounts the LV

Sidebar links for services, volumes, sync, "New agent," and Cancel
all used `<.link navigate={...}>`. `push_navigate/2` is documented
(`deps/phoenix_live_view/lib/phoenix_live_view.ex:1089-1107`) as:

> The current LiveView will be shutdown and a new one will be mounted
> in its place.

All of those routes resolve to the same module (`WorkspaceLive`,
`:service`/`:volume`/`:sync` live actions). Remount re-ran `mount/3`,
which re-derived `workspace_state` with `previous = nil`:

```elixir
defp derive_workspace_state(_ws, svcs, previous) do
  ...
  case previous do
    :starting -> if any_running?, do: :started, else: :starting
    :stopping -> if any_running?, do: :stopping, else: :stopped
    _ -> if any_running?, do: :started, else: :stopped
  end
end
```

With `previous = nil` and `any_running? = false` (compose up hadn't
landed yet), the result is `:stopped`. The transitional `:starting`
state was simply in-memory on the previous LV process — the remount
threw it away.

### Bug #2 — `agent_display_status/1` called `Registry.lookup` at render time

`BoomLooperWeb.Components.Sidebar.agent_display_status/1` computed
liveness on every render:

```elixir
not agent_alive?(id) -> :sleeping  # => Registry.lookup at render time
```

Any click that rebuilt `:agents` (which happens on `select_agent`,
`on_status_changed`, etc.) triggered a re-render; every re-render ran
`Registry.lookup/2` for each agent row. That lookup is
authoritatively-correct but a transient miss — under load, during a
supervisor restart window, or across a fleeting ETS/Registry race —
flips the row to `:sleeping` for one paint.

Compounding it, the agent list rows had no stable DOM id. When
`<.agent_list_item :for={agent <- @agents}>` re-rendered, LiveView
diffed by position: if anything adjacent to an agent row changed
(a new service appeared, an agent was removed), the DOM nodes for
*other* agents could be reused in place but with their
`transition-colors` CSS replaying — visually indistinguishable from
a data flash.

## Fixes

### Bug #1

Changed every same-module link from `navigate` to `patch`:

- `lib/boom_looper_web/live/workspace_live/components/sidebar.ex` —
  services, volumes, sync, "New agent," Cancel
- `lib/boom_looper_web/live/workspace_live/components/chat.ex` —
  Info tab link
- `lib/boom_looper_web/live/workspace_live/components/services.ex` —
  Console link
- `lib/boom_looper_web/live/workspace_live/agent_lifecycle.ex` —
  `do_spawn_agent` now `push_patch`
- `lib/boom_looper_web/live/workspace_live.ex` — all intra-LV
  `push_navigate` calls are now `push_patch` (agent-not-found,
  delete-volume, boot-failed, setup-agent-hop)

`handle_params/3` already owned all the per-action assign resets,
so no additional assign plumbing was needed. `push_navigate` to
cross-LV routes (`/`, `/system`, `/connect`) is left alone — that
*should* unmount.

Also hardened the `docker_connected?` plumbing:

- Mount seeds `:docker_connected?` (note the trailing `?`) from
  `BoomLooper.Docker.Observer.connected?/0`.
- `on_disconnected` / `on_reconnected` write the same assign.
- The sidebar now reads `@docker_connected?` from the socket rather
  than calling the `docker_connected?/0` helper at render time.

The old code wrote `:docker_connected` (no `?`) and the sidebar read
`:docker_connected?`, so the assign was effectively dead code — the
sidebar's only source of truth was a render-time function call. It
happened to work, but made render a non-pure function. Cleaned up.

### Bug #2

Cached liveness at assign-produce time:

- `AgentLifecycle.annotate_liveness/1` adds `:alive?` to a summary
  map via a single `Registry.lookup/2`.
- `AgentLifecycle.list_workspace_agents/1` pipes every agent through
  `annotate_liveness/1`.
- `WorkspaceLive.on_resumed/2` and `on_status_changed/2` now run
  their per-agent updates through `annotate_liveness/1` so the flag
  stays coherent across broadcasts.
- `Components.Sidebar.agent_display_status/1` prefers the cached
  `:alive?` flag; it only falls back to `agent_alive?/1` for
  unannotated maps (tests, dead-render edges).

Added stable DOM ids on sidebar list items:

- `agent-row-#{id}` on the wrapper div of each agent row
- `service-row-#{name}` on each service row
- `volume-row-#{name}` on each volume row
- `<.row>` now accepts an `:id` attribute (wired through every
  variant: `as={:div}`, `navigate/patch` link, `phx_click` button)

LiveView patches DOM nodes by id when present, so the agent row for
agent X stays stitched to the same node across re-renders even when
the list is rebuilt — no more CSS transition replays mid-click.

## Sweep findings

Audited every `lib/boom_looper_web/live/**/*.ex`. Other live views
(`ProjectLive`, `ProjectListLive`, `SystemWorkspacesLive`,
`SystemQuarantineLive`, `SystemDockerLive`, `SystemPortsLive`,
`ConnectLive`, `SystemLive`) were clean:

- All `push_navigate` / `<.link navigate>` calls are to a *different*
  LV module, which is the correct usage.
- No Registry-lookups-at-render-time. Registry usage in `ProjectLive`
  /`SystemWorkspacesLive` sits behind helpers that execute during
  `mount` or `refresh` — once per broadcast, not once per row.
- `SystemWorkspacesLive.refresh/1` over-eagerly rebuilds the whole
  workspaces list on every event, but LiveView's assign diff elides
  the render when `SystemStats.workspace_stats/0` returns the same
  structure. Noted as a mild CPU waste, not a flap.

## Still suspect

- **`ChatAgent.list_agents/0` makes a 2-second-timeout GenServer
  call per agent.** Called on every sidebar rebuild
  (`select_agent` → `list_workspace_agents` → `list_agents`). With
  N agents and one slow mailbox, this could stall the LV handle_info
  queue and make subsequent broadcasts pile up. Not a flap per se —
  the view stays consistent — but a latency cliff. Separate problem;
  won't fix in this pass.
- **`derive_workspace_state` uses the observer's function call for
  docker-connected truth** rather than the cached assign. That's
  deliberate — the function is authoritative and cheap, and we want
  `on_changed` to reflect the true connection state even if a
  concurrent `on_disconnected` assign hasn't landed yet. If the
  observer's `connected?/0` ever becomes expensive, revisit.
- **`StateMachine.transition(:started, :stopped)` is not allowed**,
  but `derive_workspace_state` falls back to observable truth on
  `:error`. That's intentional (container dying externally should
  flip the UI to Stopped), but it does mean the state machine's
  guard is advisory rather than enforced. Worth thinking about
  whether the "observable truth" fallback should emit a warning.

## How the bugs would surface again

If someone adds a new sidebar link that stays inside `WorkspaceLive`,
they must use `<.link patch>`, not `<.link navigate>`. The `row/1`
component in `BoomLooperWeb.Components.SideNav` exposes both
parameters; `navigate` is still the right tool when linking to a
different LV module.

If someone adds a new `<.link>` / `push_*` call from a handler in
`workspace_live.ex`, the same rule: `push_patch` for intra-module
targets, `push_navigate` only when crossing to another LV.

If a new place surfaces agent info in the UI, run any newly-minted
agent summary through `AgentLifecycle.annotate_liveness/1` before
assigning. Otherwise `agent_display_status/1` falls back to the
live-lookup path and the flash returns.
