# Configuration

Every knob in Loopyard, in one place. If you're asking "where does X live," grep for it here first.

## Environment variables

Read at runtime, overriding defaults baked into code.

| Variable | Default | What it does |
|---|---|---|
| `LOOPYARD_HOME` | `~/.loopyard` | Root of per-user state: compose dirs, workspace metadata, agent logs, secrets, SSH host keys, signing secrets (the `rpc` cookie is the one exception — see below). Test env uses `$PWD/.loopyard_home` via `config/test.exs`. |
| `PORT` | `4000` | Phoenix HTTP port. Read at runtime in dev (`config/dev.exs`) and prod (`config/runtime.exs`). |
| `LOOPYARD_BIND` | `127.0.0.1` | IP the dev endpoint binds (`config/dev.exs`). `0.0.0.0` exposes the whole web UI to the LAN — security-relevant; an unparseable value falls back to loopback, the safe direction. |
| `SSH_PORT` | `0` (random) | Port for the built-in SSH server (`Loopyard.SSHServer`). `0` picks a free port. |
| `SECRET_KEY_BASE` | required in prod | Phoenix secret — `config/runtime.exs` raises if it's missing in prod. Dev and test use committed literals (`config/dev.exs`, `config/test.exs`), which is why the MCP bridge signs with its own `mcp_token_secret` instead. |
| `PHX_HOST` | `example.com` | Prod-only: the `url: [host:]` the endpoint advertises (`config/runtime.exs`). |
| `PHX_SERVER` | unset | Prod-only: when set, a release starts the HTTP listener (`server: true`). An embedded release that wants the app without a listener leaves it unset. |
| `LOOPYARD_AUTH_PASSWORD` / `LOOPYARD_AUTH_USERNAME` | unset | HTTP Basic Auth (`LoopyardWeb.Plugs.BasicAuth`). Setting the password enables it; username is optional (any username accepted when unset). Read into `:auth_password` / `:auth_username` in `config/runtime.exs`. |
| `USER` | — | Fallback for the workstation id (`Workstation.default_id/0`): `git config user.name` first word → `$USER` → `"workstation"`. |
| `LOOPYARD_DOCKER_TESTS` | unset | `1`/`true` re-enables the Docker daemon gate in the test env (`config/test.exs` → `:docker_enabled`). Pair with `mix test --include docker`. |
| `LOOPYARD_LONG_TIMEOUTS` | unset | `1` raises the per-test ExUnit timeout from 2 s to 30 s (`test/test_helper.exs`) — CI's docker-e2e job sets it. |
| `LOOPYARD_CHROME` | auto-detected | Path to the Chrome/Chromium binary `mix loopyard.shot` renders screenshots with. |
| `ANTHROPIC_API_KEY` / Claude Code auth token | — | Consumed by the Claude Code SDK subprocess. Not read directly by Loopyard. |
| `LOOPYARD_MCP_PORT` | `4030` | Port for the dedicated ACP MCP bridge listener (`LoopyardWeb.MCP.Listener`) — a separate `0.0.0.0` Bandit endpoint so in-container ACP harnesses can reach Loopyard's control-plane tools via `host.docker.internal`. |
| `LOOPYARD_MCP_URL` | derived | Override the base URL a container uses to reach the MCP bridge (default `http://host.docker.internal:<LOOPYARD_MCP_PORT>`). Set this when the Docker-host alias isn't `host.docker.internal`. |

## Application config (`config/*.exs`)

Read via `Application.get_env(:loopyard, key)`. Overridable at runtime in `config/runtime.exs`.

| Key | Default | What it does |
|---|---|---|
| `:clone_mode` | `:sync` | Project clone strategy — `:sync` blocks until clone finishes, `:async` returns immediately and clones in the background, `:disabled` (test env) skips cloning entirely. |
| `:auth_password` / `:auth_username` | `nil` | HTTP Basic Auth for the web UI (`LoopyardWeb.Plugs.BasicAuth`). `nil` password = auth off. Populated from `LOOPYARD_AUTH_*` in `config/runtime.exs`; `nil` in test. |
| `:launch_secret` | random per boot | The `/launch/SECRET?path=…` onramp token. Not a config knob: `Application.start/2` mints it with `:crypto.strong_rand_bytes` and `put_env`s it; `LaunchController` and the project list read it back. |
| `:activity_sound` | `true` | Whether `LoopyardWeb.ActivitySound` starts (ffmpeg/mp3 encoders for the ambient bed). `false` in test. |
| `:volume_reader` | `Loopyard.VolumeIO` | Injection seam for the volume READ path (`Attachments`, `AttachmentController`, `ClaudeContext`). Tests swap in `Loopyard.Test.FakeVolumeIO`. |
| `:agent_model` | `"sonnet"` | Model new coding agents run on (`Initializer`): an alias (`sonnet`/`opus`/`haiku`/`fable`) or full model id. Dev sets `"claude-fable-5"`. Change + restart to switch the whole instance. |
| `:agent_reconciler_interval_ms` | `30_000` | How often `Agent.Reconciler` diffs ETS against the registry for drift (`/system/reconcilers`). |
| `:agent_idle_reap_hours` | `4` | `ChatAgent.IdleReaper` stops the CLI subprocess of an agent idle this long (the conversation resumes on the next send). |
| `:autostart_workspaces_on_boot` | `true` | Whether `Application` boots every registered workspace's supervisor tree at startup. |
| `:max_consecutive_crashes` | `5` | Unexpected CLI deaths in a row before the restart loop gives up and the user is told (`ChatAgent.Restart`). |
| `:max_message_bytes` | `1_048_576` (1 MB) | Cap on one chat message's payload (`ChatAgent`). **Compile-time** (`Application.compile_env`) — a change needs a recompile. |
| `:docker_enabled` | `true` | The daemon gate: `false` makes every Docker shell-out short-circuit (`Docker.daemon_disabled?/0`). Test env derives it from `LOOPYARD_DOCKER_TESTS`. |
| `:forbid_real_docker_resources` | `false` | `true` (test env) raises on any MUTATING `docker` call so a test can never create/destroy real containers or volumes. |
| `:resource_prefix` | `"loopyard-"` | Prefix on every Docker resource name Loopyard owns (`Docker.prefix/0`). `"loopyard-test-"` in test so a stray real call can't collide with a dev install. |
| `:saga_journal_default` | `true` | Whether a `Saga` journals its steps to `sagas.log` when the caller doesn't say. `false` in test. |
| `:operator_policy` | `Loopyard.Operator.Policy.Default` | The swappable attention/routing policy behind `Operator.Policy` (`rank/2`). One-module swap or config number, same pattern as the Harness seam. |
| `:operator_digest_enabled?` | `true` | Whether `Operator.Digest` records turn-end one-liners into the `:operator_digest` ring for `recent_activity`. `false` in test. |
| `:notifications_log?` | `true` | Whether `Notifications.Log` persists the inbox to `~/.loopyard/notifications.log` (see the per-workspace table below). `false` in test. |
| `:mutagen_runner` | `&System.cmd/3` | Injection seam for the Mutagen CLI. Tests override with a fake to avoid shelling out. |
| `:attachment_max_bytes` | `26_214_400` (25 MB) | Per-file cap for chat attachments (`allow_upload :max_file_size`). Tests shrink it to exercise the too-large path. |
| (module attrs) `Loopyard.Attachments` | 5 MB / image, 20 MB / prompt, png·jpeg·gif·webp | Inline image limits for prompt blocks (`@max_inline_bytes`, `@max_inline_total`, `@inline_mimes`); `Attachments.Cache` holds ≤32 MB of served bytes (`@max_bytes`). |
| `:container_io` | `Loopyard.ContainerIO` | Injection seam for by-container file I/O (`copy_in/3`, `write_file/3`, `read_file/2` against an absolute path in a running container) — the operator's attachment store. Tests use `Loopyard.Test.FakeContainerIO`. |
| `:attachment_writer` | `Loopyard.VolumeIO` | Injection seam for chat attachments' write path (`copy_in/3` + `write_file/3` into the code volume). Tests use `Loopyard.Test.FakeAttachmentWriter` (on-disk fake volumes). Limits live as module attributes on `LoopyardWeb.Live.WorkspaceLive.Attachments`: 10 files per message, 25 MB each. |
| `:container_ready_check` | `nil` | Injection seam for SyncMonitor's "is the destination container up" probe. Tests override; production uses the real Docker check. |
| `:crash_backoff_base_ms` | `2_000` | Base backoff for the CLI auto-restart loop in `ChatAgent`. Exponential from here up to a cap. |
| `:docker_probe_ms` | `10_000` | DockerDaemon probe interval (`docker version`, 5s guard). `nil` disables probing entirely (test env). |
| `:docker_probe_fun` / `:docker_heal_fun` | real probe / colima restart | Injection seams for DockerDaemon tests — same pattern as `:mutagen_runner`. The real heal is `colima stop -f` + `colima start`, userland only. |
| `:agent_turn_retries` | `3` | Auto-retries for a turn that fails on a transient upstream error (529/overload/execution). The SYSTEM is the retry loop — one quiet chat note on the first attempt, EventLog after; only when all fail does the text return to the composer with a clear error. `0` opts out (tests use this to exercise the give-up path). |
| `:sync_ready_probe_ms` | `200` (module default) | Delay between SyncMonitor container-readiness probes (5 attempts). Tests set `5`. |
| `:interrupt_deadline_ms` | `1_500` (module default) | How long a warm interrupt (`cancel_turn`) may take before the agent gives up and hard-restarts. Tests set `200`. |
| `:rate_limit_retry_grace_ms` | `1_000` (module default) | Grace added past a rate-limit reset before the auto-retry fires. Tests set `50`. |
| `:pending_drain_settle_ms` | `4_000` | Delay before draining `pending_sends` onto a freshly (re)spawned CLI (`:drain_resumed_pending`). Right after session/load the harness subprocess may not be writable yet ("ProcessTransport is not ready for writing"). Tests set `0`. |
| `:agent_thinking` | `:adaptive` | Extended-thinking config passed to the harness per session. `:adaptive` lets the model scale reasoning to the turn (streams into the chat's thinking bubble before tool calls); `:disabled` turns it off; `{:enabled, budget_tokens: N}` caps it. Applies on the next session start. |
| `:default_harness` | `Loopyard.Harness.ACP` | Which harness adapter a new agent uses (`Loopyard.Harness.{ACP,Fake}`). ACP drives the real Claude Code harness in-container over the Agent Client Protocol (the host-execution `Harness.Claude` was deleted — containment is the boundary). Test env uses `Fake`. The agent stores the module, so a change applies to newly-spawned agents (existing ones on the next replay). **Caveat:** token usage is real under claude-agent-acp@0.60.0+, but dollar cost is not surfaced — the cost panel reads $0 for ACP agents (IMPROVEMENTS.md #16). |
| `:model_windows` | map (see `config.exs`) | Per-model context-window sizes in tokens; keys are `String.starts_with?` prefixes so dated variants match. **Add a row when a new frontier model ships** — an unlisted model logs loudly + assumes `:model_window_default`. |
| `:model_window_default` | `200_000` | Fallback window for a model not in `:model_windows`. Conservative on purpose. |
| `Loopyard.PortRegistry, :port_range` | `4000..9999` | Host port range used by `PortRegistry.assign/3`. Exhaustion returns `{:error, :port_pool_exhausted}`. Keep it outside the ephemeral port range to avoid collisions with transient outbound connections. |
| `LoopyardWeb.Endpoint, :http, :port` | `4000` | HTTP port. Env-overridable via `PORT` in `runtime.exs`. |
| `:phoenix, :filter_parameters` | `["password", "secret"]` | Param keys redacted from request/event logs. `"secret"` covers the `request_secret` masked field so a submitted key never lands in the log. Setting this overrides Phoenix's `["password"]` default — keep both. |
| `:acp_mcp_listener` | `[enabled: true, port: 4030, ip: {0,0,0,0}]` | The dedicated ACP MCP bridge listener (`LoopyardWeb.MCP.Listener`). `enabled: false` (test env) skips it entirely. Bound to `0.0.0.0` so workspace containers can reach it; every request is bearer-authed + agent-scoped (`Loopyard.MCP.Token`). |
| `:acp_mcp_url` | `nil` | Base-URL override for the MCP bridge (same as `LOOPYARD_MCP_URL`). `nil` → `http://host.docker.internal:<listener port>`. |
| `:agent_harness` | `:claude` (`Loopyard.Harness.Catalog.default/0`) | Which harness a NEW agent runs on when nothing picks one: `:claude` (`claude-agent-acp`) or `:codex` (`codex-acp`). Per-agent choice lives in `session_opts[:harness]` (the sidebar picker → `ChatAgent.set_harness/3`) and wins over this. Every harness speaks ACP through the same `Harness.ACP` connection; the Catalog entry is the whole per-vendor difference (adapter binary, orphan-sweep match, credential keys, launch env, brief delivery). |
| `:acp_model` | `"claude-opus-4-8"` | Default model for a new **Claude** agent (applied via `session/set_model`). Not applied to other harnesses — Codex boots on its adapter's own default unless the picker names a model. |
| `:send_wakes_agent?` | `true` | Whether sending a message to a dead/asleep agent WAKES it (boots its workspace group if needed, resumes the agent, then delivers) — the "wakes on your next message" contract. `false` in test env: the wake boots real supervisors (and possibly compose), which wedges the shared WorkspaceSupervisor in tests; sends there get an instant `:unavailable` instead. |
| `:change_counts_enabled?` | `true` | Whether `Loopyard.ChangeCounts` computes per-workspace changed-file counts (the overview's ±N badge): async `git_status` on agent idle + a ~5-min sweep, cached in the `:ws_change_counts` ETS table, published via `Events.ChangeCounts` on delta. `false` in test env — the recomputes are real git shell-outs. |
| `:work_container_memory` | `"8g"` | **Hard memory cap on every work container** (`docker run --memory`/`--memory-swap`). The Claude Code harness runs inside and can leak into tens of GB; this ceiling means the kernel OOM-kills the bloated process INSIDE the container (contained) instead of the pressure hitting the host. Applied at create AND retro-applied to existing containers via `docker update` on `ensure_up`. Set `nil`/`""` to disable (unbounded — not recommended). |
| `:harness_memory_monitor_enabled?` | `true` | Whether `Loopyard.Harness.MemoryMonitor` runs (Layer 2 — proactive reclaim). Sweeps `docker stats`, cleanly restarts an **idle** agent whose work container crossed `:harness_memory_soft_limit_bytes`, reclaiming a leak before the hard cap OOM-kills it mid-turn. `:ignore` (no child) when `false` (test env). |
| `:harness_memory_soft_limit_bytes` | `4 GiB` | Soft threshold for the monitor above — an idle agent's container over this is proactively restarted. Keep it comfortably under `:work_container_memory` so reclaim happens before the hard cap. |
| `:harness_memory_sweep_ms` | `60_000` | How often the memory monitor samples the fleet. |

### `:aural` (extracted Mix package — `packages/aural`)

Configured via `Application.put_env(:aural, key, value)`. Set in `config/config.exs`.

| Key | Default | What it does |
|---|---|---|
| `:pubsub` | required | The `Phoenix.PubSub` server name the channel broadcasts on. Loopyard sets this to `Loopyard.PubSub`. Raises on every subscribe/broadcast if missing. |
| `:idle_timeout_seconds` | `300` | Per-channel idle reaper threshold. After this many seconds with zero subscribers across all topics, the channel terminates. Visiting the URL again respawns it under the same ID with fresh state. |

## Compile-time module attributes

Constants baked into modules at compile time. Change means recompile.

| Module | Attribute | Value | What it does |
|---|---|---|---|
| `Loopyard.Events.ChatAgent` | `@topic` | `"chat_agents"` | PubSub topic for all-agent events (publishers live in `lib/loopyard/events/`). |
| `Loopyard.ChatAgent` | `@ets_table` | `:chat_agents` | ETS table for agent state snapshots. |
| `Loopyard.AgentLog` | `@log_version` (in ServiceManager) | `1` | ETF log schema version. Bump for structural changes; add a migrator. |
| `Loopyard.Events.WorkspaceServices` | `@topic` | `"workspace_services"` | PubSub topic for cluster lifecycle events. |
| `Loopyard.Workspace.ServiceManager` | `@status_table` | `:service_status_cache` | ETS cache of last-known service status per workspace. |
| `Loopyard.Workspace` | `@config_dir` / `@config_file` | `".loopyard/repo"` / `"workspace.json"` | Host-side workspace metadata location. |
| `Loopyard.Tools.Container.Helpers` | `@max_agent_output` | `8_000` | Byte cap on tool output before truncation for the agent's context window. |
| `Loopyard.EvalRunner` | `@default_timeout` | `2_700_000` | Eval run timeout in ms (45 min). |
| `Loopyard.SSHServer` | `@default_port` | `0` | SSH server port (overridden by `SSH_PORT`). |

## Dev-only tooling

| Tool | Where it's wired | Purpose |
|---|---|---|
| Tidewave MCP | `LoopyardWeb.Endpoint` — `plug Tidewave` inside the `code_reloading?` block | Exposes `/tidewave/mcp` for in-Claude-session Elixir eval, log fetch, process introspection. Localhost-only by default. Connect via `claude mcp add --transport http tidewave http://localhost:4000/tidewave/mcp`. |
| Boundary | `:boundary` dep installed; no `use Boundary` declarations yet | When declared, will enforce cross-namespace dependency rules at compile time. See [IMPROVEMENTS.md](IMPROVEMENTS.md) for the scoped wire-up task. |
| StreamData | `:stream_data` dep (`:dev`/`:test`) | Property-based testing for state machines, replay, and streaming buffers. See [TESTING.md](TESTING.md#property-based-tests). |

## Per-workspace config in volumes

Lives in the code volume under `.loopyard/workspace/`. Agents write these; Loopyard reads them.

| Path | Purpose |
|---|---|
| `.loopyard/workspace/Dockerfile` | Workspace container image build recipe. |
| `.loopyard/workspace/docker-compose.yml` | Compose project for the workspace. Processed by `Compose.process_agent_compose/3` — host mounts, privileged, host networking, host port pins, and external networks are rejected. See [SECURITY.md](SECURITY.md). |
| `.loopyard/workspace/agents.log` | Append-only ETF log of agent events. Compacted at boot when it exceeds 5 MB. |
| `~/.loopyard/notifications.log` (gated by app config `:notifications_log?`, `false` in test) | The inbox store's own ETF log (`Loopyard.Notifications.Log`): every raised/settled item as an upsert; compacted to one snapshot past 5,000 records. Replayed into the `:notifications` ETS table at boot. |

## Per-workspace metadata on host

Lives at `${LOOPYARD_HOME}/workspaces/<workspace_id>/` (the "compose dir") and in the repo at `.loopyard/repo/`.

| Path | Purpose |
|---|---|
| `${LOOPYARD_HOME}/workspaces/<id>/docker-compose.yml` | Processed compose file written by ServiceManager for `docker compose` CLI commands. Derived from the volume copy. |
| `${LOOPYARD_HOME}/workspaces/<id>/.loopyard/workspace/*` | Synced snapshot of volume-side compose + Dockerfile (via `sync_volume_to_host/2`). |
| `${LOOPYARD_HOME}/projects.json` | `ProjectStore` persistence — one row per project (git URL, path, volume flag). |
| `${LOOPYARD_HOME}/ports.json` | `PortStore` persistence — every `PortRegistry` entry (workspace / service / container_port → host_port). See [SECURITY.md § 4](SECURITY.md). |
| `${LOOPYARD_HOME}/secrets.json` | Secret store with optional per-secret `scope: [workspace_id | project_id]`. See [SECURITY.md](SECURITY.md). |
| `~/.loopyard/cookie` | Erlang distribution cookie for `mix loopyard.rpc`. **Always `~/.loopyard`, never `LOOPYARD_HOME`** (`mix loopyard.server`) — `LOOPYARD_HOME` is for workspace data, and a direnv-cached stale value would otherwise make the server and `rpc` disagree on the cookie. |
| `${LOOPYARD_HOME}/mcp_token_secret` | Per-install random signing key for the ACP MCP bridge's bearer tokens (`Loopyard.MCP.Token`, mode 0600, generated on first use). Deliberately NOT `secret_key_base`, which is a committed constant in dev. Security-relevant — see [SECURITY.md](SECURITY.md#acp-mcp-bridge--the-network-edge-of-the-sandbox). |
| `${LOOPYARD_HOME}/push_token` | Per-install bearer token (`Loopyard.PushToken`, mode 0600) gating `PUT /env/:key` — pushing env vars into Loopyard from your dev machine. Shown in the Workstation UI. |
| `${LOOPYARD_HOME}/web_push.json` | Web Push VAPID keys + browser subscriptions (`Loopyard.WebPush`), minted once at boot. |
| `${LOOPYARD_HOME}/canonical_projects.json` | `CanonicalStore` persistence — `project_id => %{name, remote, workspaces}` for canonical-backed projects, re-registered on boot. |
| `${LOOPYARD_HOME}/sagas.log` | `Saga.Journal` — append-only length-prefixed ETF log of saga steps (same framing as `AgentLog`), replayed for rollback after a crash. |
| `${LOOPYARD_HOME}/worktrees/` | Root of every `Source.Local` git worktree (`Source.Local.Worktree.root/0`). |
| `${LOOPYARD_HOME}/workstations/<id>/env.json` | Workstation env vars (`Loopyard.Workstation.Env`, mode 0600) — `KEY=value` pairs (`CLAUDE_CODE_OAUTH_TOKEN`, `GITHUB_TOKEN`, …) injected as `-e` into the console + every agent container at run. |
| `${LOOPYARD_HOME}/workstations/<id>/Dockerfile` | The workstation identity's image recipe (`Loopyard.Workstation`) — built as `loopyard-ws-<id>`, home volume `loopyard-ws-<id>-home`. |
| `${LOOPYARD_HOME}/ssh/ssh_host_*_key` | SSH host keys for the built-in server. |
| `<project>/.loopyard/repo/workspace.json` | Human-facing metadata: project name, system prompt. Can be committed to git. |

## Tunables worth documenting

Constants that aren't configurable today but could reasonably become so. If you're adding a flag, prefer app config with a sensible default over a new env var.

| Constant | Location | Default | Why it's here |
|---|---|---|---|
| Agent log compaction threshold | `AgentLog.Compactor.maybe_compact/1` (`@default_threshold_bytes`; `AgentLog.maybe_compact/1` delegates to it) | `5_000_000` bytes | Compact when the log exceeds this. Override per call with `threshold_bytes:`. |
| Tool output truncation | `Tools.Container.Helpers.truncate_for_agent/2` | `8_000` bytes | Cap on the bytes an agent sees from a tool call. Full output still streams to the UI. |
| Docker CLI retry | `Docker.run_with_retry/5` | 3 attempts, 100/300/900ms | Transient daemon errors only (see `Docker.transient_error?/1`). |
| Agent max_turns | caller-supplied | unbounded | Could default-cap runaway agents; today relies on user stopping them. |

## Injection seams (for tests)

If you need a test to avoid shelling out or hitting real infra, these are the expected handles.

| App-config key | Production default | Test override |
|---|---|---|
| `:mutagen_runner` | `&System.cmd/3` | Fake that returns stubbed output (see `test/loopyard/source/local/mutagen_test.exs`). |
| `:container_ready_check` | Real Docker probe | Fake returning `true`/`false` on demand. |
| Tool `:backend` in `ChatAgent` opts | `Loopyard.Harness.ACP` (via `:default_harness`) | `Loopyard.Harness.Fake` for unit tests that don't want a real CLI. |

## How to add a new setting

1. Decide the lifetime: **per-user** → `LOOPYARD_HOME` file. **per-project** → `.loopyard/repo/workspace.json`. **per-workspace** → `.loopyard/workspace/*` in the volume. **per-machine** → env var or app config. **per-session** → function arg / GenServer state.
2. If it's app config, give it a sensible default via `Application.get_env(:loopyard, key, default)` — don't require the operator to set it for the happy path.
3. Add a row to this file in the right section.
4. If the setting affects a security boundary (volume scope, secrets, compose validation), also add a row to [SECURITY.md](SECURITY.md).
