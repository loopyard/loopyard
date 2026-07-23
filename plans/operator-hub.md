# Plan: The Operator — one chief-of-staff agent + surface

## Vision (Brad's words, consolidated)

Combine the **workstation**, the **operator agent** (the workspace-less agent
for the one workstation), and the **sound** (aural) into a single **Operator**.
They're all facets of one operator and are spread out right now.

The operator is a **chief of staff, not a decider**. It keeps tabs on projects
as they come and go, knows when turns finish, and — done right — becomes the one
place you run everything from. It:

- keeps tabs on all projects/workspaces and **is told when their turns finish**;
- can **dispatch work** to workspace agents when it chooses to;
- **pulls detail on demand** — a workspace's status and its chat — when it needs
  specifics, rather than holding everything (careful about context: it can't
  decide everything, it delegates and queries);
- has its **activity drive the ambient sound**;
- lives on one surface that shows **sound + operator chat + what's working**, and
  the **speaker icon becomes the operator icon**.

## Principle

> The operator is the HUB. It already has a body (a ChatAgent in the workstation
> container) and a nervous system (the `Events.Activity` backbone that already
> aggregates every agent's activity across every project). This feature gives it
> **eyes and hands** into other workspaces, a **lean way to learn what finished**,
> **one home**, and **ownership of the sound** — reusing existing seams, additive
> first. Context stays lean by default: headlines are pulled, details fetched only
> on demand.

## What already exists (build ON this — do not rebuild)

- **Operator agent** — `Loopyard.Operator` (`lib/loopyard/operator.ex`): a
  workspace-less `ChatAgent` in the workstation container (`loopyard-ws-<id>`,
  `$HOME`), stable per-workstation id + ETF-log history, operator-scoped MCP
  tools (`Loopyard.Tools.ControlPlane`: create-project ×3, `ListProjects`, `Gh`,
  `Exec`). Route `/operator` → `LoopyardWeb.OperatorLive` (reuses the workspace
  `chat_panel` + `AgentEvents`).
- **Activity backbone** — `Loopyard.Events.Activity` (`lib/loopyard/events/activity.ex`):
  global `"activity"` + per-project `"project_activity:<id>"` topics; producers
  call `record(agent_id, kind, summary)` (kind `:status | :tool`); event carries
  `{agent_id, agent_name, workspace_id, project_id, kind, summary, at}`.
  `StatusChanged` already mirrors onto it (`events/chat_agent.ex:78`). "Turn
  finished" = `:status`/`"idle"`. This is the cross-project "watch everything"
  seam — `subscribe_global/0`, `subscribe_project/1`.
- **Sound** — Aural engine (`packages/aural`, `Aural.Channel`: `fire/2` chimes,
  `set_activity/2` continuous 0..1 level, `pick_track/2`); `LoopyardWeb.ActivitySound`
  already drives chimes off the Activity backbone; ambient engine mounted once in
  `root.html.heex` (channel `"activity"`). Speaker icon = `Common.sound_control/1`
  (`common.ex:392`) — navigates to `/sound`, 5 placements (nav, global_sidebar,
  app_header, workspace chat, operator).
- **Dispatch primitives** — `ChatAgent.enqueue_message/2` (durable send to an
  agent), `ChatAgent.Lifecycle.list_agents/0` / `list_agents_for_workspace/1`,
  `Onboarding.spawn_agent/2`.
- **Board data** — `WorkspaceTree`, `Birdseye`, `ChangeCounts`, `Activity`
  already power the god-mode sidebar; reuse for the operator's board.
- **MCP tool pattern** — `use Loopyard.Tool`; register in a toolkit
  (`Tools.ControlPlane.@tools` for operator scope); `ToolConfig.acp_operator_tools/0`
  → `MCP.ToolRouter` (scope `:operator`). Per-agent token gate binds a session to
  one `agent_id` (`tool.ex` `authorize_agent/2`) — an operator dispatch tool runs
  host-side under the operator's token and targets *other* agents by validated id.

## Decision: how the operator learns what finished → **digest-pull** (foundation)

Completions accumulate in a durable **operator digest** (a ring buffer fed by the
Activity backbone), as one-liners ("✓ garryslist/main finished (2m)"). The
operator reads the digest via a tool when it takes a turn, and pulls full detail
(`peek_workspace`) only when it decides to dig in. Nothing is auto-injected into
its LLM context. Push-nudge and watch-list are **additive layers on top of this
same digest** — start here; add them only if it feels too passive.

## Phases

### Phase 1 — Operator's eyes & hands (operator-scoped MCP tools, pull-based)
New `Loopyard.Tools.ControlPlane.*` modules, registered in `@tools`:
- `list_workspaces` — projects → workspaces → agent status / who's working
  (reuse `WorkspaceTree` / `Activity`; no shell-out).
- `peek_workspace(workspace_id | agent_id, limit)` — one workspace's status +
  recent chat, on demand (reuse the `RecallConversation` read via
  `ChatAgent.MessageWindow`, cross-agent, operator-scoped, read-only).
- `dispatch(target, message)` — enqueue a task to a workspace agent
  (`enqueue_message/2`); resolve target by workspace id or agent id; validate it
  exists; NEW cross-agent send (none exists today).
- `recent_activity(limit)` — read the operator digest (Phase 2).

### Phase 2 — The operator digest ("told when things finish", compact)
- `Loopyard.Operator.Digest` (GenServer + ETS ring, per workstation): subscribes
  `Events.Activity.subscribe_global/0`; on a workspace agent's `:status`→idle (and
  notable tool events) appends a compact one-liner `{project, workspace, summary, at}`.
  Deduped, bounded (~last N). Read by `recent_activity`. NOT injected into context.
- Config-gated like `ChangeCounts` (off in test).

### Phase 3 — The unified operator surface (`/operator`)
Rework `OperatorLive` into the one home:
- **operator chat** (existing `chat_panel`), plus
- a live **working board** (projects/workspaces + status + recent completions,
  from `WorkspaceTree`/`Birdseye`/`Digest`), plus
- **sound controls inline** (fold in what `/sound` offers).
Keep `/operator` the canonical entry.

### Phase 4 — Operator drives sound + icon swap
- Drive the ambient channel from the OPERATOR: `set_activity` for a continuous
  "operator working" level (currently unused), `fire` on completions it surfaces.
  Extend/replace `ActivitySound` wiring so the operator is the ambient presence.
- Replace `Common.sound_control/1`'s speaker SVG with an **operator icon** and
  point it at `/operator` (all 5 placements) — the operator becomes the ambient
  affordance; sound lives inside its surface.

### Phase 5 — Cutover
Wire end-to-end, verify live (operator lists/peeks/dispatches; digest fills on a
real workspace turn finishing; sound follows operator; icon → `/operator`),
then a deliberate merge to `main` + reboot.

## Constraints / guardrails
- **Context-lean by default** — headlines pulled, details on demand; nothing
  auto-injected. Push/watch are later layers.
- **PubSub boundary** — new broadcasts only from `lib/loopyard/events/*`.
- **ETS ownership** — the digest table goes through `StateKeeper`.
- **Simplest / least bugs / show status** — reuse `Activity`, `WorkspaceTree`,
  `enqueue_message`, the MCP tool macro, `sound_control`. Additive first.
- **Worktree + deliberate cutover** — build here (isolated from the shared dev
  server); Brad cuts to main + reboots when a phase is proven.

## Files (anticipated)
- new `lib/loopyard/tools/control_plane/list_workspaces.ex`, `peek_workspace.ex`,
  `dispatch.ex`, `recent_activity.ex`
- `lib/loopyard/tools/control_plane.ex` (+`@tools`), `chat_agent/tool_config.ex`
- new `lib/loopyard/operator/digest.ex` + `StateKeeper` table + supervisor child
- `lib/loopyard/operator.ex` (system prompt: describe the new tools + the
  chief-of-staff role)
- `lib/loopyard_web/live/operator_live.ex` (+ board + sound) ; `sound_live.ex` fold-in
- `lib/loopyard_web/components/common.ex` (`sound_control` → operator icon)
- `lib/loopyard_web/components/icon.ex` (operator glyph)
- `ActivitySound` + ambient wiring (operator-driven)
- docs: `CLAUDE.md` (operator section), `ARCHITECTURE.md`
