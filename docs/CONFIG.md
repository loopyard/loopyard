# Configuration

Every knob in Loopyard, in one place. If you're asking "where does X live," grep for it here first.

## Environment variables

Read at runtime, overriding defaults baked into code.

| Variable | Default | What it does |
|---|---|---|
| `LOOPYARD_HOME` | `~/.loopyard` | Root of per-user state: compose dirs, workspace metadata, agent logs, secrets, SSH host keys, cookie. Test env uses `$PWD/.loopyard_home` via `config/test.exs`. |
| `PORT` | `4000` | Phoenix HTTP port (via `config/*.exs`, not runtime). |
| `SSH_PORT` | `0` (random) | Port for the built-in SSH server (`Loopyard.SSHServer`). `0` picks a free port. |
| `LOOPYARD_DEV_SECRET_KEY_BASE` | required in dev/prod | Phoenix secret (see `config/runtime.exs`). |
| `ANTHROPIC_API_KEY` / Claude Code auth token | — | Consumed by the Claude Code SDK subprocess. Not read directly by Loopyard. |
| `LOOPYARD_MCP_PORT` | `4030` | Port for the dedicated ACP MCP bridge listener (`LoopyardWeb.MCP.Listener`) — a separate `0.0.0.0` Bandit endpoint so in-container ACP harnesses can reach Loopyard's control-plane tools via `host.docker.internal`. |
| `LOOPYARD_MCP_URL` | derived | Override the base URL a container uses to reach the MCP bridge (default `http://host.docker.internal:<LOOPYARD_MCP_PORT>`). Set this when the Docker-host alias isn't `host.docker.internal`. |

## Application config (`config/*.exs`)

Read via `Application.get_env(:loopyard, key)`. Overridable at runtime in `config/runtime.exs`.

| Key | Default | What it does |
|---|---|---|
| `:clone_mode` | `:sync` | Project clone strategy — `:sync` blocks until clone finishes, `:async` returns immediately and clones in the background. |
| `:mutagen_runner` | `&System.cmd/3` | Injection seam for the Mutagen CLI. Tests override with a fake to avoid shelling out. |
| `:attachment_writer` | `Loopyard.VolumeIO` | Injection seam for chat attachments' write path (`copy_in/3` + `write_file/3` into the code volume). Tests use `Loopyard.Test.FakeAttachmentWriter` (on-disk fake volumes). Limits live as module attributes on `LoopyardWeb.Live.WorkspaceLive.Attachments`: 10 files per message, 25 MB each. |
| `:container_ready_check` | `nil` | Injection seam for SyncMonitor's "is the destination container up" probe. Tests override; production uses the real Docker check. |
| `:crash_backoff_base_ms` | `1_000` | Base backoff for the CLI auto-restart loop in `ChatAgent`. Exponential from here up to a cap. |
| `:docker_probe_ms` | `10_000` | DockerDaemon probe interval (`docker version`, 5s guard). `nil` disables probing entirely (test env). |
| `:docker_probe_fun` / `:docker_heal_fun` | real probe / colima restart | Injection seams for DockerDaemon tests — same pattern as `:mutagen_runner`. The real heal is `colima stop -f` + `colima start`, userland only. |
| `:agent_turn_retries` | `3` | Auto-retries for a turn that fails on a transient upstream error (529/overload/execution). The SYSTEM is the retry loop — one quiet chat note on the first attempt, EventLog after; only when all fail does the text return to the composer with a clear error. `0` opts out (tests use this to exercise the give-up path). |
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
| `Loopyard.ChatAgent` | `@topic` | `"chat_agents"` | PubSub topic for all-agent events. |
| `Loopyard.ChatAgent` | `@ets_table` | `:chat_agents` | ETS table for agent state snapshots. |
| `Loopyard.ChatAgent` | `@default_crash_backoff_base_ms` | `1_000` | Default for the CLI auto-restart backoff (overridable via app config). |
| `Loopyard.AgentLog` | `@log_version` (in ServiceManager) | `1` | ETF log schema version. Bump for structural changes; add a migrator. |
| `Loopyard.Workspace.ServiceManager` | `@services_topic` | `"workspace_services"` | PubSub topic for cluster lifecycle events. |
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

## Per-workspace metadata on host

Lives at `${LOOPYARD_HOME}/workspaces/<workspace_id>/` (the "compose dir") and in the repo at `.loopyard/repo/`.

| Path | Purpose |
|---|---|
| `${LOOPYARD_HOME}/workspaces/<id>/docker-compose.yml` | Processed compose file written by ServiceManager for `docker compose` CLI commands. Derived from the volume copy. |
| `${LOOPYARD_HOME}/workspaces/<id>/.loopyard/workspace/*` | Synced snapshot of volume-side compose + Dockerfile (via `sync_volume_to_host/2`). |
| `${LOOPYARD_HOME}/projects.json` | `ProjectStore` persistence — one row per project (git URL, path, volume flag). |
| `${LOOPYARD_HOME}/ports.json` | `PortStore` persistence — every `PortRegistry` entry (workspace / service / container_port → host_port). See [SECURITY.md § 4](SECURITY.md). |
| `${LOOPYARD_HOME}/secrets.json` | Secret store with optional per-secret `scope: [workspace_id | project_id]`. See [SECURITY.md](SECURITY.md). |
| `${LOOPYARD_HOME}/cookie` | Erlang distribution cookie for `mix loopyard.rpc`. |
| `${LOOPYARD_HOME}/workstation/env.json` | Workstation env vars (`Loopyard.Workstation.Env`, mode 0600) — `KEY=value` pairs (`CLAUDE_CODE_OAUTH_TOKEN`, `GITHUB_TOKEN`, …) injected as `-e` into the console + every agent container at run. |
| `${LOOPYARD_HOME}/ssh/ssh_host_*_key` | SSH host keys for the built-in server. |
| `<project>/.loopyard/repo/workspace.json` | Human-facing metadata: project name, system prompt. Can be committed to git. |

## Tunables worth documenting

Constants that aren't configurable today but could reasonably become so. If you're adding a flag, prefer app config with a sensible default over a new env var.

| Constant | Location | Default | Why it's here |
|---|---|---|---|
| Agent log compaction threshold | `AgentLog.maybe_compact/1` default | `5_000_000` bytes | Compact when the log exceeds this. |
| Tool output truncation | `Tools.Container.Helpers.truncate_for_agent/2` | `8_000` bytes | Cap on the bytes an agent sees from a tool call. Full output still streams to the UI. |
| Docker CLI retry | `Docker.run_with_retry/5` | 3 attempts, 100/300/900ms | Transient daemon errors only (see `Docker.transient_error?/1`). |
| Agent max_turns | caller-supplied | unbounded | Could default-cap runaway agents; today relies on user stopping them. |

## Injection seams (for tests)

If you need a test to avoid shelling out or hitting real infra, these are the expected handles.

| App-config key | Production default | Test override |
|---|---|---|
| `:mutagen_runner` | `&System.cmd/3` | Fake that returns stubbed output (see `test/loopyard/source/local/mutagen_test.exs`). |
| `:container_ready_check` | Real Docker probe | Fake returning `true`/`false` on demand. |
| Tool `:backend` in `ChatAgent` opts | `Loopyard.Harness.Claude` | `Loopyard.Harness.Fake` for unit tests that don't want a real CLI. |

## How to add a new setting

1. Decide the lifetime: **per-user** → `LOOPYARD_HOME` file. **per-project** → `.loopyard/repo/workspace.json`. **per-workspace** → `.loopyard/workspace/*` in the volume. **per-machine** → env var or app config. **per-session** → function arg / GenServer state.
2. If it's app config, give it a sensible default via `Application.get_env(:loopyard, key, default)` — don't require the operator to set it for the happy path.
3. Add a row to this file in the right section.
4. If the setting affects a security boundary (volume scope, secrets, compose validation), also add a row to [SECURITY.md](SECURITY.md).
