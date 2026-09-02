# Plan: The Operator — one chief-of-staff agent + surface

> **Build status (branch `operator-hub`, worktree):** Phases 1–4 built + compiling.
> Phase 1 (cockpit tools), Phase 2 (digest + recent_activity), Phase 3 (unified
> `/operator` surface + working board), Phase 4 (operator icon + operator-driven
> sound) are done. **Phase 5 (cutover)** is pending: Brad merges to `main` +
> reboots to verify live; CI runs the suite; then tune the surface/sound feel and
> add the delete-lifecycle tools + tests. Known follow-ups: operator-driven sound
> level currently fires from `OperatorLive` (works while /operator is open);
> moving it to `ActivitySound` makes it global. Project/workspace DELETE tools
> (`manage_*`) not yet built — creates + consent cards work today.

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

> The operator is the HUB — **Brad's cockpit for all of Loopyard**. It already
> has a body (a ChatAgent in the workstation container) and a nervous system (the
> `Events.Activity` backbone that already aggregates every agent's activity across
> every project). This feature gives it **eyes and hands** into other workspaces,
> a **lean way to learn what finished**, **one home**, and **ownership of the
> sound** — reusing existing seams, additive first. Context stays lean by default:
> headlines are pulled, details fetched only on demand.

## The cockpit (what Brad does in it)

Mostly chat. Ask it anything about Loopyard's state and drive everything through it:
- **Status**: what projects/workspaces/agents/ports exist, what's running, what
  just finished, machine/system status.
- **Ports**: open/close a workspace's port (network exposure).
- **Lifecycle**: spin up / tear down projects and workspaces (consent-gated).
- **Dispatch**: hand a task to a workspace agent when it chooses.
It just needs a bare "something finished" ping — not the details — and can pull
detail on demand.

## Context discipline (optimize the RIGHT thing)

Tool *definitions* are cheap (~10–15 tools ≈ 1–2% of the window; Claude Code
picks from that many cleanly). What blows context is tool *outputs* accumulating
over a long conversation. So the rule is NOT "as few tools as possible" (that
cripples the cockpit and turns each tool into a confusing multi-mode blob) — it's:
- **Terse outputs** (`truncate_for_agent`-style caps on everything).
- **Pull-on-demand** — one compact `overview`, details only via `peek_workspace`.
- **Consolidate naturally-parallel actions** (open/close/list ports → one `ports`
  tool) but keep distinct verbs distinct.
- The operator can compact; nothing is auto-injected into its context.

## Security boundary (unchanged, load-bearing)

The operator's `exec` runs INSIDE its workstation container — never a host shell.
Host visibility ("how much memory on this machine") comes through a NARROW,
read-only `system_status` tool (reusing `Health` / `Docker.Observer` /
`MemoryMonitor`), NOT host exec. Read docs/SECURITY.md before touching this.
Destructive lifecycle (create/clone/delete project or workspace) stays behind the
existing approval cards (`propose_*` → `Harness.Approvals`).

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

### Phase 1 — The cockpit toolset (operator-scoped MCP tools, curated ~10)
New `Loopyard.Tools.ControlPlane.*` modules, registered in `@tools`. Reads are
TERSE; detail is pulled, not dumped.

Reads:
- `overview` — ONE compact tree: projects → workspaces → agent status / who's
  working / open ports. Answers most "what's there / what's running" questions in
  one cheap call (reuse `WorkspaceTree` / `Birdseye` / `PortRegistry` / `Activity`;
  no shell-out). Replaces separate list_projects/list_workspaces/list_ports.
- `peek_workspace(workspace_id | agent_id, limit)` — one workspace's status +
  recent chat, on demand (reuse the `RecallConversation` read via
  `ChatAgent.MessageWindow`, cross-agent, operator-scoped, read-only).
- `system_status` — read-only HOST snapshot: memory, `Health` map, container /
  volume counts (reuse `Health` / `Docker.Observer` / `Harness.MemoryMonitor`).
  NOT host exec (see Security boundary).
- `recent_activity(limit)` — read the operator digest (Phase 2).

Acts:
- `ports(workspace, action: open|close, service, port)` — network exposure toggle
  (`PortRegistry.set_exposure/4`). Consolidates open/close/list.
- `dispatch(target, message)` — enqueue a task to a workspace agent
  (`enqueue_message/2`); resolve target by workspace or agent id; validate; NEW
  cross-agent send (none exists today).
- `manage_workspace(action: create|delete, ...)` — via the existing consent cards
  (`propose_fork`/`propose_delete_workspace` flows), operator-initiated.
- `manage_project(action: create_scratch|create_github|create_path|delete, ...)` —
  wraps the existing `ControlPlane` create flows + a NEW consent-gated project
  delete card.

Keep existing operator tools: `Gh`, `Exec` (container-scoped).

Model note: the operator's model is set at spawn and is a runtime toggle — Brad
wants to TRY a few (chief-of-staff routing may favor a cheaper/faster model, or
not). Not decided; keep it a one-line config, experiment during Phase 3–5.

### Phase 2 — The operator digest ("told when things finish", compact)
- `Loopyard.Operator.Digest` (GenServer + ETS ring, per workstation): subscribes
  `Events.Activity.subscribe_global/0`; on a workspace agent's `:status`→idle (and
  notable tool events) appends a compact one-liner `{project, workspace, summary, at}`.
  Deduped, bounded (~last N). Read by `recent_activity`. NOT injected into context.
- Config-gated like `ChangeCounts` (off in test).

### Phase 3 — The unified operator surface (`/operator`)
Rework `OperatorLive` into the one home. **Chat-primary** — mostly you'll see the
operator chat and just talk to it:
- **operator chat** (existing `chat_panel`) is the primary surface, plus
- a glanceable **status strip / board** (projects/workspaces + who's working,
  from `WorkspaceTree`/`Birdseye`) — secondary, not a busy feed, plus
- **sound controls inline** (fold in what `/sound` offers).
Keep `/operator` the canonical entry.

**Do NOT build a live turn-taking / completions feed** (Brad's own concern: it
reads as noise). Completions stay in the operator's pull-digest; at most a quiet
unread badge later. Consent cards (create/clone/delete) render inline as today.

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

## Follow-on — keeping the human in the loop (GitHub issues, not yet built)

Design captured as issues so the human can review before we build (epic #68):
- **#69 Attention / turn-taking view** — a low-noise surface of the workspaces
  you're actively cycling through that are waiting on you (finished a turn / asked
  a question / stalled) — NOT every workspace; scoped by engagement/recency.
- **#70 Workspace focus descriptor** — a short, agent-maintained "what we're
  working on / where we're at", updated freely (no consent), that reminds you when
  you flip in AND gives the operator lean status without pulling full chat.
- **#71 Rename project / workspace** — consent-gated rename tools (distinct from
  the free descriptor).

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
