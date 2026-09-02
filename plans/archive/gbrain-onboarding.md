> Archived Sept 2026 — merged. The operator + control-plane toolset it specified live in `Loopyard.Operator` and `Tools.ControlPlane` (`/operator`).

# Plan: run `overtonxyz/gbrain` on Loopyard, agent-driven

## Goal
The real deliverable: **an operator agent I can talk to that sets up a project**
for me, three ways —
  1. **from scratch** (blank repo),
  2. **from GitHub** (clone a repo), and
  3. **from a path on the host machine** (point at a local folder).
Each create is approval-gated. `overtonxyz/gbrain` (private Elixir/Phoenix, a
"hosting plane" that itself drives Docker) is the first real test of mode 2, and
proving it by hand is Phase 2 — it becomes the recipe the agent follows.

**Hard security boundary (mode 3):** the operator agent must NEVER read the host
filesystem. "From a path" passes a path *string* to a control-plane tool;
Loopyard ingests the folder host-side (Local source adapter / Mutagen sync into a
volume). The agent triggers ingestion and gets back a workspace — it never sees
host file contents. This matches the existing model: agents run container-only
and are already denied host-FS native tools (`ToolConfig` deny list). The
operator toolkit must add no host-read tool.

## Git / project / workspace model (so the plan is complete)
- A **project** owns a bare **canonical** git repo in a Docker volume
  (`loopyard-<project>-canonical`) — hub-and-spokes (`CanonicalRepo`).
- A **workspace** is a clone of the canonical on its **own branch**, in its own
  volume (`loopyard-<ws>-code`), mounted at `/workspace`.
- **Create paths:** scratch → `CanonicalRepo.init` (empty repo + first commit);
  GitHub → `CanonicalRepo.init_from_remote` (bare clone, token-injected); path →
  `ProjectRegistry.add(path)` (Local adapter, host-side Mutagen).
- **Integrate** (`CanonicalRepo.integrate`) rebases a workspace branch onto
  canonical `main` and pushes to the canonical — the merge gate between
  workspaces. **Push** (`CanonicalRepo.push`) syncs canonical `main` out to a
  GitHub remote. Pull-from-GitHub is the initial `init_from_remote` (and a future
  re-sync). The operator agent's job is CREATE + spawn a coding agent; integrate/
  push-to-GitHub stay with the coding agents (existing machinery), not the
  operator.

## The four pieces

1. **Control-plane agent + tools** — a special agent (custom prompt, custom
   toolkit) that can create projects/workspaces and provision them, instead of
   only coding inside one workspace.
2. **Brad-workstation tap** — reuse the existing identity mechanism so the agent
   inherits GitHub + Claude auth (already how work containers get creds).
3. **gbrain dev-env recipe** — clone the private repo, Elixir + Postgres, run
   `mix gbrain.server`.
4. **Docker host via DooD** (revised — no second Colima). gbrain's containers
   mount the existing Colima daemon's socket (`/var/run/docker.sock`) — the
   standard "avoid docker-in-docker" pattern. gbrain drives the same daemon
   Loopyard uses. The existing Colima is never touched or restarted.

## Operator hosting (FINAL — sunk-cost-corrected)
The operator is NOT a workspace/project. It's a **host-side `Harness.Claude`
agent** (the Claude CLI on the host, using the Mac's Claude + GitHub auth), with
`workspace_id: nil` and the `Tools.ControlPlane` toolkit. So: **no container, no
workspace, no project, no code volume, no git repo** — none of the workspace
apparatus. The harness seam is doing its job: workspace agents run ACP +
Claude Code in-container (they write code); the operator runs a lighter host-side
loop (it creates + delegates). `init_fresh` + persistence already no-op on a nil
workspace_id, so this needed ~zero ChatAgent surgery — the container was the only
thing forcing the workspace/project cascade, and it was self-inflicted by
defaulting to ACP. `Loopyard.Operator.ensure_agent/1` spawns it directly under
`AgentSupervisor` (lazy, idempotent, per-workstation); `LoopyardWeb.OperatorLive`
renders its chat standalone (no workspace chrome).

## Separation of duties (core principle — enforced by disjoint toolkits)
Two agents, non-overlapping jobs. The separation is enforced structurally: their
MCP toolkits share **no tool**, so neither can do the other's job even if it
tried.

- **Operator agent** (control plane, spans all projects). Its ONLY job: create
  the project/workspace shell (the 3 gated modes), spawn the workspace agent with
  a delegating brief, and step back. It reports "workspace X created, agent Y is
  setting it up — open it to watch," then it's done.
  - Toolkit = `Tools.ControlPlane` ONLY: `create_project_from_scratch/github/path`,
    `run_preview`, `status`. **No** `exec` / `write_file` / `docker_compose` /
    `read` / host-FS tools. It cannot work inside a workspace.
- **Workspace agent** (the existing coding agent, scoped to ONE workspace). Owns
  everything inside `/workspace`: the actual checkout specifics, writing
  `.loopyard/workspace/{Dockerfile,docker-compose.yml}`, deps, migrations, running
  and debugging the app.
  - Toolkit = the existing `Tools.Container` (exec, write_file, docker_compose,
    git, …). It does not create projects.

The **handoff** is the operator's create tool spawning the workspace agent with a
delegating `initial_message` ("gbrain is checked out at /workspace — set up the
Elixir+Postgres dev env, mount /var/run/docker.sock, run it"). The operator never
writes a Dockerfile; the workspace agent never creates a project. This also means
**Phase 2 IS the operator's recipe**: doing it by hand (RPC create_project +
spawn a workspace agent with that brief) is exactly what the operator will later
automate.

## What already exists (from the codebase maps)

- **Provisioning is a programmatic API** — `Loopyard.Onboarding`:
  - `create_project(name, remote: <git_url>, token: <t>)` → clones a repo into a
    canonical volume via `alpine/git` + `VolumeCloner.inject_token`
    (`onboarding.ex:38`, `canonical_repo.ex:65`).
  - `spawn_agent(ws_id, opts)` (`onboarding.ex:144`), `start_preview(ws_id)`
    (`onboarding.ex:294`, brings up `.loopyard/workspace/docker-compose.yml`).
  - `propose_fork` (`tools/container/propose_fork.ex`) already calls these from
    inside an agent tool — the proof that an agent can drive the control plane.
- **Workstation `brad` = identity** — a `$HOME` Docker volume
  (`loopyard-ws-brad-home`) + `env.json` holding `GITHUB_TOKEN` /
  `CLAUDE_CODE_OAUTH_TOKEN` (`workstation/env.ex`). Work containers mount that
  volume at `/home/brad` and source `~/.profile`, so agents inherit gh + Claude
  auth automatically (`work_container.ex:208`). Private clone of gbrain works
  out of the box on the brad identity. `gh` on the host is authed (repo scope).
- **Toolkits are pluggable** — a toolkit is a module with `__tool_server__/0`
  returning `%{name, tools: [...]}`; each tool `use Loopyard.Tool`
  (`tools/container.ex:67`). An agent's toolkit + system prompt are already
  honored opts (`Initializer.start_session/3` `tools:` at `initializer.ex:53`,
  `Prompt.build_system_prompt/2` custom prompt at `prompt.ex:31`) — they're just
  not threaded through the current spawn path (`lifecycle.ex do_start_agent`).
- **Approval gate** — `Harness.Approvals` (the Approve/Deny card behind the
  `Propose*` tools). A control-plane agent can either gate each create through
  this, or call `Onboarding` directly (ungated).
- **Docker today** — one Colima VM (`default`), reached over the unix socket via
  the `colima` docker context. No TCP, no socket passed into containers.

## Phased plan

### Phase 1 — Docker host via DooD (PROVEN, zero code)
Verified live: a container with `-v /var/run/docker.sock:/var/run/docker.sock`
reaches the existing Colima daemon (host saw 5 containers; the mounted container
saw those 5 + itself, daemon 27.3.1). So gbrain drives the existing daemon by
mounting the socket — the standard alternative to docker-in-docker.
- **Injection is agent-written** — gbrain's `.loopyard/workspace/docker-compose.yml`
  gets `volumes: ["/var/run/docker.sock:/var/run/docker.sock"]` on the service(s)
  that talk to Docker (optionally `DOCKER_HOST=unix:///var/run/docker.sock`, but
  mounting at the default path needs no env var). **No Loopyard code.**
- **Blast-radius trade-off (flagged):** DooD shares the daemon with Loopyard —
  gbrain's containers can see/control ALL containers, including Loopyard's own.
  Acceptable for a local hosting-plane dev env and matches the local-only
  posture, but gbrain *could* `docker rm` Loopyard's containers. If that ever
  bites, the isolation answer is a second Colima (reachable via the proven
  `host.docker.internal` path) — but we're not paying for that now.

### Phase 2 — get gbrain running (prove the recipe, by hand)
Do this before automating, so the agent has a known-good path.
- `mix loopyard.rpc "Loopyard.Onboarding.create_project(\"gbrain\", remote:
  \"https://github.com/overtonxyz/gbrain\", token: <brad GITHUB_TOKEN>)"` — the
  token pulled from brad's `env.json`. Creates the project + `main` workspace +
  work container.
- `Onboarding.spawn_agent(ws_id, initial_message: "set up + run gbrain")` on the
  brad identity. The agent (in-container, brad creds) writes
  `.loopyard/workspace/Dockerfile` + `docker-compose.yml` (Elixir 1.20 + Postgres
  16, `mix deps.get`, `mix ecto.setup`, `mix gbrain.server`), with
  `DOCKER_HOST=<gbrain-docker endpoint>` injected so gbrain can drive its Docker.
- `Onboarding.start_preview(ws_id)` → cluster up. Verify via `probe_http`.
- Deliverable: gbrain reachable; a captured, repeatable recipe.

### Phase 3 — the operator agent + toolkit (the "do it for me" agent)
- `Loopyard.Tools.ControlPlane` (new toolkit), three creation tools matching the
  three modes — each **approval-gated** via `Harness.Approvals`:
  - `create_project_from_scratch(name)` → `Onboarding.create_project(name)`.
  - `create_project_from_github(name, owner_repo, branch \\ "main")` →
    `Onboarding.create_project(name, remote:, token: <brad gh token>)`.
  - `create_project_from_path(name, host_path)` → `ProjectRegistry.add(host_path)`.
    **Host-side only** — passes the path string to the Local adapter; returns a
    workspace, never file contents. The tool does NOT read the path.
  - Every create tool ends by `Onboarding.spawn_agent(ws_id, initial_message:
    <delegating brief>)` — the handoff. The operator then reports and stops; the
    workspace agent does the checkout/setup/run. The operator never sets up a
    dev env itself.
  - plus `run_preview(ws_id)` and, later (Phase 4), read-only status tools.
- These tools are NOT workspace-scoped, so they must not depend on
  `Helpers.resolve_container/1` / the `agent_id` container boundary — they take
  explicit args and operate on the registry (`authorize_agent` caveat from the
  tool map). The operator agent is deliberately given NO host-FS native tools.
- Thread `tools:` + `system_prompt:` through `Lifecycle.do_start_agent`
  (`lifecycle.ex:53`) so a control-plane agent can be spawned with this toolkit
  and a custom prompt (the "operator" agent), on the brad identity.
- **Creation stays approval-GATED** (locked). The clone-into-new-project /
  new-workspace tools each request an Approve/Deny card via `Harness.Approvals`
  before touching `Onboarding` — same guardrail as `propose_fork`. This is the
  "agent I can use to clone repos into new projects & workspaces," with a human
  in the loop on every create.
- A place to launch/talk to it: a "New operator agent" affordance, or reuse the
  Operated dashboard card.

### Phase 3.5 — embedded agent mini-apps ("chat-in-chat" / quote)
What makes the operator agent usable instead of fire-and-forget: after it spawns
a workspace agent, it embeds a LIVE mini-app of that agent in its own stream, so
you drive the setup from one place. Fits the model because chats are already
PubSub + server-driven + multiplayer — an embed is just a message that references
another agent and renders a slice of it.

- **New message type** `role: :embed`, payload `%{agent_id, kind}` (kind:
  `:mini_app | :question | :approval | :status`). Persisted + broadcast like any
  message, so all viewers see it (multiplayer).
- **`agent_embed/1` component** — a compact live card: referenced agent's name +
  status dot + its ONE actionable thing (pending question / Approve-Deny card /
  "running mix deps.get…" status / running-app preview) + "open →" to the full
  chat. The host LiveView subscribes to the referenced agent's topic (bounded
  fan-out — a handful of embeds).
- **Interaction routes to the referenced agent.** The Questions/Approvals brokers
  are already keyed by `agent_id`; embedded buttons carry the EMBEDDED agent's id
  so answering resolves against it, not the host chat. You answer the workspace
  agent's question from the operator chat.
- **It's a QUOTE, not a recursive transcript** — one level deep, a curated slice.
  An embed never renders the referenced agent's OWN embeds. This depth cap is
  what keeps chat-in-chat from spiraling.
- **Reusable primitive** — any stream can embed any agent's slice (operator →
  its workspaces; a workspace agent → a fork it spawned; the dashboard → agents).
  Build it as a standalone component, not operator-specific.
- Tricky bits: event dispatch by embedded id in the host LiveView; cap embed
  count; don't re-render on the embedded agent's every token (throttle to
  status/actionable changes).

### The "new project" UI — keep it, re-role it
Keep `/projects/new` (scratch/folder forms) as the **direct fast path**. The
operator agent is the **conversational path** and is what finally implements the
GitHub "Soon" stub. The `+ New project` affordance can offer both: "quick form"
or "ask the operator." Not redundant — a form vs a dialogue.

### The control-plane MCP — internal now, external-ready
`Tools.ControlPlane` is already an **MCP server** (`__tool_server__/0` →
`"loopyard-control-plane"`), consumed in-process by the operator agent's Claude
session via `ToolConfig.build_mcp_servers`. So "an MCP into Loopyard that this
agent uses" already exists — and any Loopyard agent can be given it by passing
`tools: [Loopyard.Tools.ControlPlane]`.

**External-harness seam (NOT exposed — noted for later).** To let an *external*
harness (another Claude Code, Codex, a remote agent) drive Loopyard's control
plane, mount the same toolkit over HTTP the way Tidewave is mounted in
`LoopyardWeb.Endpoint` (a `/mcp/control-plane` plug, dev-gated / auth-gated).
Two things to resolve before exposing it:
  1. **Identity/approval routing.** The gated tools key `Approvals` by
     `agent_id`; an external caller has no Loopyard agent. Give external sessions
     a synthetic operator identity (per workstation) so approval cards still land
     in *a* human's stream.
  2. **Auth.** External exposure is a real network surface — must be
     authenticated (unlike the internal in-process wiring). Ties into the
     deferred front-door auth plug.
Deliberately not built now; the toolkit is structured so this is an additive
HTTP mount, not a rewrite.

### Phase 4 (future) — the operator agent keeps tabs on running projects
The same operator agent is the natural home for read-only monitoring: which
projects/workspaces are up, agent status, failing services, drift. Read-only
tools (no gate needed — nothing is created) over `WorkspaceTree.global`,
`Health`, `Compose.ps`, the LogBuffer. Turns the operator into a standing
"how's everything doing" agent, not just a one-shot provisioner. Out of scope
for the first cut; noted because the toolkit seam makes it cheap later.

## Decisions (locked)
1. **Sequencing** — recipe by hand first (Phase 1–2), then the operator agent
   (Phase 3). Get gbrain running fast; give the agent a proven recipe.
2. **Approval gate** — GATED. The operator agent pops an Approve/Deny card per
   create, via `Harness.Approvals` (the `propose_fork` pattern).
3. **Transport** — TCP via `socat` + `host.docker.internal` (proven).
4. **socat lifecycle** — start as a throwaway one-liner during the spike;
   promote to a managed `mix loopyard.docker_host` / launchd job once it works.

## Risks
- Unauth TCP Docker daemon = host-takeover surface (mitigate: bind to
  localhost/vmnet only, not the LAN).
- gbrain may need secrets/env beyond a bare `mix phx.server` (DB URL, gstack
  config) — surface via `request_secret` / the brad `env.json`.
- The `authorize_agent` one-agent-per-workspace assumption doesn't fit a
  control-plane agent; its toolkit must be written not to rely on it.
