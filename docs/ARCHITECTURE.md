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
Loopyard.Supervisor (:one_for_one)
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
  └── LoopyardWeb.Endpoint
```

**Key properties:**
- StateKeeper starts first, creates ALL named ETS tables, and lives longest. No other module creates ETS tables.
- Docker.Observer starts before Endpoint so the ETS cache is warm for the first LiveView mount.
- ServiceManager.terminate does NOT call compose down — containers persist across server reboots.
- Every fire-and-forget Task runs under TaskSupervisor (never bare `Task.start`).

## Container model (Docker Compose)

Each workspace's containers are orchestrated via Docker Compose. Agents write `Dockerfile` and `docker-compose.yml` directly to `.loopyard/workspace/`. ServiceManager runs compose up/down. The code volume is the source of truth for project files — all containers mount it at `/workspace`, and all file operations (agent tools, terminal, VolumeIO) go through Docker.

```
Compose project: loopyard-{workspace_id}
  ├── workspace (built from Dockerfile, agents exec here, sleep infinity)
  ├── dev (built from Dockerfile, runs dev command)
  ├── postgres (stock service)
  └── redis (stock service)
```

All containers share a Docker network and the code volume. Container naming: `loopyard-{workspace_id}-{service}-1`.

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

## Hub-and-spokes git storage (v1 — `Loopyard.CanonicalRepo`)

The v1 spine (#13/#15/#17). Each project has ONE **canonical** bare git repo in its own volume (`loopyard-<project_id>-canonical`) — the hub, the source of truth, that nobody works in. Workspaces are **clones** of it in their own code volumes (the spokes), each on its own branch.

`Loopyard.CanonicalRepo` runs every git operation in a **transient git container** (`docker run --rm` against `alpine/git`, with the relevant volume(s) mounted, via `Docker.docker/2`):

- `init/1` — new blank project (empty canonical, `main` + initial commit).
- `init_from_remote/3` — existing project (bare clone of a remote / GitHub).
- `fork/4` — clone canonical → a workspace volume on a new branch (cut from any base).
- `integrate/4` — rebase the workspace's branch onto canonical `main` + fast-forward (the merge gate; conflicts leave the workspace mid-rebase for the agent to resolve).
- `push/3` — sync canonical → a git remote (the "sync container" role).

No persistent git server, no host paths, no Mutagen — git is the only thing that crosses between hub and spokes, and Loopyard mediates `fork`/`integrate`/`push` by mounting the right volumes. Isolation is physical (separate volumes); the merge is the one human-gated crossing. Onboarding decouples cleanly: `init`/`init_from_remote` + `fork` give a **code-ready** workspace volume; the compose preview cluster (`Compose.up`) is a separate, opt-in step.

**The v1 layer on top of the engine:**

- `Loopyard.Onboarding` — the "one flow" door (#14/#19). `create_project/2` (new blank, or existing via `remote:`) inits the canonical, registers the project, and materializes a **code-ready `main` workspace** (no compose cluster — preview is opt-in). `fork/3` cuts a branch+workspace from any base. `start_preview/1` / `stop_preview/1` bring the compose cluster up/down on demand (materialize the agent's compose from the volume via `Helpers.sync_volume_to_host` + `Compose.up`). `attach_remote/2` + `sync/2` hook the project to a git remote and push the canonical to it. Canonical-backed workspaces register `:ready` directly (the engine materializes synchronously — no Source-adapter saga).
- `Loopyard.CanonicalStore` — durable persistence: a JSON map at `<LOOPYARD_HOME>/canonical_projects.json` (project → name/remote/workspaces). `Onboarding.restore/0` re-registers projects + workspaces on boot (hooked into `Application.start`), skipping any whose volumes are gone. Volumes are durable; the store records just enough to rebuild the ETS rows.
- **Git is the real thing, gated only on the dangerous edge.** A workspace's `origin` is the project's **real GitHub remote** (repointed after the fast local clone from the canonical cache — see `CanonicalRepo.fork/checkout` + `origin_repoint`; the token is NEVER baked into `.git/config`, auth is a gh credential helper). So an agent drives normal git — commit/push/pull/fetch/rebase/checkout/branch feature branches freely. The `git` tool's push-to-main / force / remote-delete redirect is a **UX guardrail, not a boundary** (an agent has `exec` + the token; real enforcement is GitHub branch protection). The `canonical` bare repo is now just an invisible **local speed-cache** for fast forks, not a git authority.
- **Boundary-crossing approval** (#10) — fork / integrate / delete-workspace are gated behind a human decision via the mini-app approval cards: the agent calls `propose_fork` / `propose_integrate` / `propose_delete_workspace` (`Tools.Container.*`), which post a `role: :approval` card through the `Loopyard.Harness.Approvals` broker. On approval the tool runs the real op host-side (`Onboarding.fork_from_workspace/3`, `CanonicalRepo.integrate/5` — which rebases + pushes to **GitHub main** with a throwaway token, the real merge gate; `Workspace.Destructor`). In-sandbox ops are NOT gated — only new-workspace / merge-to-main / delete come through here. (This replaced the earlier `Loopyard.Workflow` policy seam, which the approval-card flow bypassed.)

## Working is the default — `WorkContainer` vs the preview cluster (north-star D10)

A workspace is a git branch in its own env. *Most* interaction is just "read/write code, run commands, let the agent show its work" — that must NOT require booting the project's dev cluster (postgres, dev server, stock services). So there are **two distinct things** a workspace can have running, and they're decoupled:

- **The work container (`Loopyard.Workspace.WorkContainer`)** — the cheap, Loopyard-owned place an agent acts. Built from `priv/workspace-base/Dockerfile` (alpine + git/gh/ssh/bash/curl/rsync, `sleep infinity`), built on demand and cached. Named `loopyard-<ws>-work`, it mounts the `loopyard-<ws>-code` volume at `/workspace`. Boots sub-second once the base image is cached. This is what "working is the default" means: you don't boot containers to start working.
- **The preview/dev cluster** — the agent-written `.loopyard/workspace/docker-compose.yml`, brought up via `Onboarding.start_preview/1` (the `loopyard-<ws>-workspace-1` + service containers). Opt-in, for when you want to *run* the app.

**The seam (in `Loopyard.Workspace`):**
- `container_running?/1` — is the **compose** workspace service up (preview running)?
- `working?/1` — is *either* the compose workspace container or the cheap `WorkContainer` up? (Can an agent act at all?)
- `ensure_working/1` — make the workspace workable now: reuse the compose container if preview is up, else bring up the cheap `WorkContainer`.
- `agent_container/1` — the container an agent execs into: the compose `workspace` service when preview is up (real project toolchain), else the work container.

**Where it's wired:**
- `Tools.Container.Helpers.resolve_container/1` (the target of every container tool — exec/grep/glob/tree/file_info/logs/ports) resolves via `agent_container/1`, lazily `ensure_working/1` if nothing is up. It NEVER boots the preview cluster to run a tool.
- `AgentBoot`'s `:ensure_services` step, for volume-backed workspaces, calls `Workspace.ensure_working/1` (cheap) instead of booting the compose cluster. Legacy host bind-mount projects keep the old `ServiceManager.start_services` path. So spawning an agent makes the workspace *workable*, not *fully running*.
- The workspace UI (`States.workspace_not_running`) defaults to "Ready to work — start an agent"; booting the preview env is a quiet secondary action. The stored workspace `status` still tracks only the preview cluster (`:stopped`/`:starting`/`:running`); "working" is a derived query, not a stored status.

**The work container is also the harness host.** Its base image (`priv/workspace-base/Dockerfile`) carries Node + the ACP adapter (`@zed-industries/claude-code-acp`), so the **real** Claude/Codex harness runs *inside* the box via `docker exec -i loopyard-<ws>-work claude-code-acp` (ACP = JSON-RPC over stdio), against the mounted code volume — natively, with native tools/skills/subagents. This is the north star: the box hosts a real harness, it doesn't reimplement one; new harnesses plug in by adding their adapter to the base image, nothing else about the sandbox changes. Validated headlessly: the work container completes an ACP `initialize` handshake with the real harness (`test/loopyard/workspace/work_container_test.exs`); a full prompt additionally needs in-container auth (the parked credential piece — see #3/#12).

The base image carries git/bash/curl/node + the harness adapter — *not* the project's own toolchain (elixir, the app's deps, postgres). Running the project's tests/build or the app itself still needs the project image, i.e. the **preview env**. Cheap container = code + git + harness; preview = run the app.

## Environment layering — image · home · code · services

An agent's environment is **composed from independent layers, each owning one concern with one mechanism**. The design invariant is orthogonality: any layer changes without touching the others. Full model + build order in [plans/agent-home-and-refresh.md](../plans/agent-home-and-refresh.md).

```
agent = image (tools) + /home/<name> (you) + /workspace (code), launched with a login shell
```

| layer | owns | scope | mechanism |
|-------|------|-------|-----------|
| **image** | the tools (ruby, node, gh, git, the harness adapter) | per project (shared) | a Dockerfile (`FROM loopyard/base`) |
| **`/home/<name>` volume** | *identity* — creds, dotfiles, env | per seat (per person) | a named Docker volume |
| **`/workspace` volume** | the code | per branch | a named Docker volume |
| **services** | db, redis, web | per project (inherited) | one Loopyard-authored compose |
| **networking / exposure** | who can reach what | per workspace | control plane (per-ws nets, `PortExposer`) |

Swap the home volume → different person, same everything else. Grow the image → more tools, same identity/code. New branch → new code volume, same image/cluster. Nothing leaks across the seams.

**Identity is a home volume (the "workstation" pulled apart).** Identity is *not* an entity or a per-user image — it's a named Docker volume mounted at `/home/<name>` with `$HOME` set to match, so every tool resolves creds there. The bench keeps **root** (the pet model installs tools live — `apt`/`mise`/`gem` need it; true non-root is a cattle/prod concern), and commands run through a portable login wrap (`Docker.with_login_profile/1` — sources `~/.profile` via plain `sh -c`, no `-l`/bash dependency). The durable noun is the volume; `docker volume ls --filter label=loopyard.role=home` is the list of identities (naming convention + labels, no separate registry to drift). Creds are **files under `$HOME`, nowhere else** — file creds at their paths, env vars as `export` lines in `~/.profile`. Never a secret in container config (`-e SECRET=…`) or an image layer. Every credential surface the host has (keychain, OAuth, env, files) is normalized to files-under-`$HOME` by a **host-side intake step** — the one place tool-specific quirks live — so the container sees a single exception-free surface. The thing formerly called a "workstation" is just a **throwaway shell container with the home volume mounted at `$HOME`**: log in (or run the pump scripts) and set up creds; only what lands in `/home/<name>` persists.

**The bench grows in place; cattle build from the record.** The per-workspace `WorkContainer` is the always-on bench and harness host. It boots `loopyard/base` and accretes the project toolchain *into itself* at runtime (`mise install`, `bundle install`) — the **pet** model, no swap to a fatter image to gain a tool. The Dockerfile the agent writes is the **record** (cold-start + reproducibility), not the mechanism. test/staging/prod are **cattle** — built fresh from that Dockerfile + lockfile, clean and reproducible — which keeps the pet honest (a live-installed tool missing from the Dockerfile fails the next clean build). Dependencies live in the lockfile + a shared bundle volume, never baked per-add; adding a gem = edit Gemfile + `bundle install` + restart the web *process*, never an image rebuild.

**The bench is mission control, not a member of the cluster.** The harness runs *in* the bench (ACP) and reaches services **over the network** (`db:5432`) — it never execs into a service to do work. From the bench the agent also spins up / tears down **ephemeral clusters** for isolated jobs (e.g. a test suite against a frozen commit + a clean db, run in parallel while the dev bench keeps working). Environments are per-branch and ephemeral, fanning into one prod: **dev** (the bench's preview cluster), **test** (clean ephemeral run), **staging** (preview URL), **prod** (the deploy target — a deploy axis, not an exec axis).

**One compose definition per project, inherited by branches.** The cluster is authored once (git-tracked, or Loopyard project-seeded) and every workspace inherits it — a new branch never regenerates a cluster from scratch. Definition is shared; running instances stay cheap and isolated per branch (one postgres with a per-branch *database*, only the app spun per-branch).

**Cross-agent isolation is structural, not trust-based.** Each workspace's cluster is its own compose project on its own Docker bridge network, which Docker firewalls apart by default (`DOCKER-ISOLATION` chains drop inter-bridge traffic — no ping cluster→cluster by name or IP). The bench has **no docker socket**, so it can't bridge networks or reach a neighbor's containers; every container op funnels through the `docker_compose` tool on the control plane, where **compose-processing** strips the four escape hatches (`ports:`, `external` networks, `network_mode: host`, multi-network attach). External exposure is the control plane's alone, via `PortExposer`. The agent can *request* exposure; it cannot *open* a hole — five independent reasons agent A can't reach agent B, none depending on the agent behaving.

## Docker interface

**Every Docker CLI call goes through `Loopyard.Docker`.** No `System.cmd("docker", ...)` anywhere else.

| Function | Use case |
|----------|----------|
| `Docker.docker(args, opts)` | One-shot commands. Returns `{:ok, output}` or `{:error, output}`. Has timeout, telemetry, env options. |
| `Docker.stream(args, callback, opts)` | Long-running commands with streaming output. Calls `callback` per chunk. |
| `Docker.open_port(args, opts)` | Raw Port for custom stream handling (Observer events, terminal). |

`Docker.Observer` maintains an ETS cache of all `loopyard-*` containers and volumes, updated by `docker events` stream. LiveViews read from ETS (microseconds) instead of shelling out to docker (100ms+).

## MCP tool architecture

Each agent tool is a standalone module. No monolithic tool files.

```
lib/loopyard/tools/
├── container.ex              ← toolkit (lists 22 tool modules in __tool_server__/0)
├── container/
│   ├── helpers.ex            ← shared: resolve_container, validate_path, etc.
│   ├── exec.ex               ← one tool
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
│   ├── volumes.ex
│   ├── file_url.ex
│   ├── app_url.ex
│   ├── git.ex
│   └── file_info.ex
├── agents.ex                 ← agent-to-agent tools
├── secrets.ex                ← secret management tools
└── workspace.ex              ← workspace metadata tools
```

**Tool module structure** (using `Loopyard.Tool` macro):

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
    # tool logic
  end
end
```

The macro generates `__tool_name__/0`, `__description__/0`, `input_schema/0`. You just write `execute/2`. Params arrive with atom keys (SDK atomizes them via `safe_atomize_keys`).

**Tool output truncation:** Long command output is truncated for agents (via `Helpers.truncate_for_agent`, ~80 lines) to conserve context tokens. The full output is streamed to the chat UI for human viewers. This keeps agent context bounded while giving humans complete visibility.

**Discovery pipeline:**
1. `ChatAgent.ToolConfig.default_tools()` → `[Tools.Container, Tools.Secrets]`. The former `Tools.Agents` toolkit is gone on purpose — see [SECURITY.md](SECURITY.md).
2. `build_mcp_servers(tools, agent_id)` returns `%{name => %{module: mod, assigns: %{agent_id: id}}}`. The SDK threads `assigns` into every `execute(params, assigns)` call; tools cross-check the model-supplied `agent_id` param against the session-bound id.
3. `build_allowed_tools/2` iterates tools, builds `"mcp__server__tool"` strings.
4. Passed to Claude SDK session → CLI contacts BEAM via JSONRPC for tool calls.

**Security boundaries enforced here:** session-bound `agent_id` (tools reject mismatched ids), workspace-scoped tool resolution (every tool derives its container/volume from the agent's own state), compose validation (no host mounts, host networking, privileged, external networks, host port pins), loopback-only port publishing, scoped secrets. Full model in [SECURITY.md](SECURITY.md).

## ChatAgent internals

Each `ChatAgent` is a GenServer owning a conversation **backend** session. There is **one agent type** — a self-determining coding agent (`priv/agents/coding/agent.md`) that inspects the workspace (`service_status` + `/workspace`) and bootstraps the dev environment only if it's actually missing, otherwise just codes. There is no setup-vs-coding split.

**The Harness behaviour is the pluggable harness seam.** `Loopyard.Harness` (`lib/loopyard/harness.ex`) defines `start_session/1`, `stream/2`, `stop/1`, `session_alive?/1`, `session_id/1`. ChatAgent / StreamHandler / multiplayer fan-out consume neutral `Loopyard.Agent.Event` structs, so swapping backends changes only the event *source*:
- `Harness.Claude` — the Claude Code SDK / CLI subprocess (today's default).
- `Harness.ACP` (`harness/acp.ex`) — drives a **real** Claude/Codex harness over the Agent Client Protocol (JSON-RPC over stdio), host-side today and in-container next (`docker exec -i <work> claude-code-acp`). North-star direction (#3); implemented + tested but not yet the default. See [SECURITY.md](SECURITY.md) for its trust boundary and [IMPROVEMENTS.md](IMPROVEMENTS.md) for open gaps.
- `Harness.Fake` — deterministic test backend.

**Inbox vs. turn execution — the durability boundary.** Loopyard owns the **durable message inbox**: message ordering, the persisted ETF message log, the `pending_sends` FIFO queue, and rate-limit/auth/backoff gating. The backend (whichever harness) owns only **turn execution** — taking a prompt and streaming a response. This is why a harness restart never loses messages: the inbox is Loopyard state, not harness state. The `send_message` LiveView event replies with a server **ack** (`%{ok: true}`) so the browser only clears the input once Loopyard has durably accepted the message.

Each `ChatAgent` GenServer (with the default backend) owns a Claude Code SDK session (CLI subprocess).

**Message storage:** Reversed list internally for O(1) prepend. `append_message` returns `{state, msg}`. `summary/1` reverses before exposing to readers. Capped at 1000 messages in memory — the ETF agent log retains full history.

**Submodules:**
- `ChatAgent.Prompt` — system prompt construction
- `ChatAgent.ClaudeContext` — mirrors CLAUDE.md + `.claude/` from the code volume to `working_dir` so the CLI's native discovery finds them
- `ChatAgent.ToolConfig` — MCP server/tool wiring
- `ChatAgent.Persistence` — ETF log append

**System prompt composition:** We pass `append_system_prompt` (NOT `system_prompt`) to the Claude Code SDK so the CLI's default system prompt — which handles `CLAUDE.md` discovery, slash command docs, and native tool descriptions — stays active. Our Loopyard-specific rules are appended on top. Using `system_prompt` would replace the default and silently turn off `CLAUDE.md` loading.

**CLAUDE.md for container-only workspaces:** GitHub workspaces store code exclusively in a volume; `working_dir` is an empty bookkeeping dir and the CLI has nothing to discover. `ClaudeContext.mirror/2` pulls `CLAUDE.md`, `CLAUDE.local.md`, `.claude/` (settings + skills + commands + agents + hooks), and any `@`-imported files from the volume into `working_dir` before the session starts. Local workspaces skip the mirror (host is already the source of truth via Mutagen).

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
lib/loopyard_web/live/
├── workspace_live.ex         ← mount, handle_*, render (the workspace view: chat + file browser + git viewer + …)
├── workspace_live/
│   ├── components.ex         ← imports all component submodules
│   ├── components/
│   │   ├── sidebar.ex        ← sidebar, service_item, volume_item, agent_list_item
│   │   ├── chat.ex           ← chat_header, agent_view, chat_panel, container_panel
│   │   ├── services.ex       ← service_log_view, console_view, all_services_view
│   │   ├── states.ex         ← booting_screen, empty_state
│   │   ├── context_panel.ex  ← right-rail agent context pane
│   │   ├── sync_detail.ex    ← Local-source sync status detail page
│   │   ├── volumes.ex        ← volume detail + tabs
│   │   ├── viewers/          ← file + git + image + binary + syntax viewers
│   │   └── formatters.ex     ← time_ago, exit_reason, service_status_text (pure functions)
│   ├── agent_lifecycle.ex    ← spawn, select, list agents
│   ├── agent_events.ex       ← handle_info for agent PubSub (status, messages, streaming)
│   ├── docker_events.ex      ← handle_info for Docker Observer (container state changes)
│   ├── diff_loader.ex        ← git diff / commit fetches (adapter-scoped pure fns)
│   ├── file_browser.ex       ← volume file browser (tree + probe_path)
│   ├── service_logs.ex       ← fetch, refresh service logs (async via TaskSupervisor)
│   └── messages.ex           ← chat_msg, streaming_bubble components
```

**Key patterns:**
- Mount renders instantly with loading skeletons. Slow data arrives via `start_async/3`.
- Docker.Observer provides container/volume state from ETS (zero docker calls from LiveViews).
- Service log fetching runs in TaskSupervisor — LiveView never blocks on `docker logs`.
- All shared state flows through GenServer → PubSub → all LiveViews.

## Port proxy system

Docker containers bind ephemeral loopback ports (e.g., `127.0.0.1:32922:3000`). Users never see these. Loopyard assigns a stable user-facing port from a global pool (4000..9999) and runs a TCP proxy between users and Docker.

```
User → PortExposer (127.0.0.1:4008 or 0.0.0.0:4008) → Docker (127.0.0.1:32922) → Container (:3000)
```

**Data flow:**
1. Compose processing calls `PortRegistry.assign/3` → sticky user-facing port (4008)
2. Compose emits `127.0.0.1::3000` — Docker picks ephemeral
3. Docker Observer detects the ephemeral port via container events
4. `PortRegistry.reconcile_proxies` starts a PortExposer: `127.0.0.1:4008 → 127.0.0.1:32922`
5. `set_exposure(true)` restarts the proxy on `0.0.0.0:4008` — same port, network-reachable

**Lifecycle is reactive.** PortRegistry subscribes to Docker Observer events. On every container state change it reconciles: starts proxies for new containers, stops proxies for dead ones, updates upstream port on container restart. No polling, no manual intervention.

**Key modules:**
- `PortRegistry` — GenServer. Assigns ports, manages proxy lifecycle, persists to `ports.json`, reconciles on Observer events
- `PortExposer` — GenServer per proxied port. TCP forwarding with byte counters, peer tracking, `bind_ip` toggle. `restart: :transient`, self-terminates after 5 consecutive upstream failures
- `PortStore` — JSON persistence at `~/.loopyard/ports.json`

**Security:** All Docker ports bind loopback-only. Network exposure is opt-in per port via `set_exposure/4`. The proxy is the only path from the network to the container — giving full connection visibility (bytes in/out, peer IPs, connection count) on `/system/ports`.

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
| `:loopyard_evals` | set | Eval run state |

## What an agent is — the template

An agent is four things brought together (`Loopyard.Agents.Template`):
**compute** (a container: the workspace's work container on the code volume,
or the identity's workstation container), **tools** (an MCP scope:
`:workspace` — the container toolkit; `:system` — `Tools.ControlPlane`),
**loop + model** (`:acp` today — a coding harness in the container; `:direct`
next — a model API loop in the BEAM), and **context** (shared doctrine blocks
under `priv/agents/_shared/` + the template's `agent.md` body + its on-demand
file catalog + runtime facts, composed by `ChatAgent.Prompt` for every agent).
Two presets exist, as code: `coding` (a workspace agent) and `system` (the
operator and its peers). `template_id` + `scope` persist on the agent record.

`Loopyard.Agents.Spawn` is the one spawn path (via `Onboarding.spawn_agent/2`);
`AgentBoot` picks its saga steps by scope; a workspace agent lands under its
`WorkspaceGroup`, a system agent under its identity's `Agents.SystemGroup`
(agent supervisor + `RestartController` keyed `{:system, identity}` +
`Checkpointer` on `<workstation>/agents.log`). `Loopyard.Agents` is the
registry of system agents and the flat read of all of them.

## Notifications — the inbox store

`Loopyard.Notifications` is ONE durable store of everything waiting on a human
(decisions: a `:question` / `:approval` / `:secret` card an agent is blocked
on) and, next, of what happened (`:finished` turns). One GenServer is the
single writer; reads go straight to StateKeeper's `:notifications` ETS table;
every change is appended to the store's own log (`~/.loopyard/notifications.log`)
and broadcast through `Events.Notifications` (`Added` / `Changed`).

**Items get in through the two card funnels.** Every decision card enters the
transcript via `ChatAgent.MessageWindow.append_message_ets/2` and settles via
`update_message_now/3`; those call `card_raised/2` and `card_status/3` (casts —
the append path never blocks on the store). `Notifications.Reconcile` diffs the
pending cards against the open items once after boot, whenever an agent
starts/resumes (coalesced), and every 60 s — the card is the truth for a
decision, so any path that bypasses the funnels still converges.

**Readers.** `Loopyard.Attention.line/0` is now a read of the store's decision
subset in inbox order (`Notifications.Priority`: approvals, questions, secrets,
finished-with-changes, finished; newest first within a tier; pins on top),
decorated with the live card from the agent's ETS summary. It used to be a
derived query that copied every agent's whole message list out of ETS on every
render of the dashboard, the rail and the deck, and inside every push payload.

## Agent persistence

Agents and messages are persisted to an append-only ETF log at `~/.loopyard/workspaces/{id}/.loopyard/workspace/agents.log`.

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
| `[:loopyard, :docker, :command]` | `Docker.docker/2` | `%{args: args, timeout: timeout}` |
| `[:loopyard, :compose, :up]` | `Compose.up/2` | `%{workspace_id: id}` |
| `[:loopyard, :compose, :down]` | `Compose.down/2` | `%{workspace_id: id}` |
| `[:loopyard, :agent, :message]` | `ChatAgent` | `%{agent_id: id, role: :user}` |

No subscribers configured by default — attach your own handlers for logging/metrics.

## Directory structure

```
# Code volume (Docker named volume code-{workspace_id})
/workspace/                     ← project root inside containers
└── .loopyard/
    ├── repo/
    │   └── workspace.json      ← metadata (name, system prompt)
    └── workspace/
        ├── Dockerfile          ← agent-written
        └── docker-compose.yml  ← agent-written

# Loopyard home directory
~/.loopyard/
├── workspaces/
│   └── {workspace_id}/
│       └── .loopyard/workspace/
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
