# Configuration

Every knob in BoomLooper, in one place. If you're asking "where does X live," grep for it here first.

## Environment variables

Read at runtime, overriding defaults baked into code.

| Variable | Default | What it does |
|---|---|---|
| `BOOMLOOPER_HOME` | `~/.boomlooper` | Root of per-user state: compose dirs, workspace metadata, agent logs, secrets, SSH host keys, cookie. Test env uses `$PWD/.boomlooper_home` via `config/test.exs`. |
| `PORT` | `4000` | Phoenix HTTP port (via `config/*.exs`, not runtime). |
| `SSH_PORT` | `0` (random) | Port for the built-in SSH server (`BoomLooper.SSHServer`). `0` picks a free port. |
| `BOOMLOOPER_DEV_SECRET_KEY_BASE` | required in dev/prod | Phoenix secret (see `config/runtime.exs`). |
| `ANTHROPIC_API_KEY` / Claude Code auth token | — | Consumed by the Claude Code SDK subprocess. Not read directly by BoomLooper. |

## Application config (`config/*.exs`)

Read via `Application.get_env(:boom_looper, key)`. Overridable at runtime in `config/runtime.exs`.

| Key | Default | What it does |
|---|---|---|
| `:clone_mode` | `:sync` | Project clone strategy — `:sync` blocks until clone finishes, `:async` returns immediately and clones in the background. |
| `:mutagen_runner` | `&System.cmd/3` | Injection seam for the Mutagen CLI. Tests override with a fake to avoid shelling out. |
| `:container_ready_check` | `nil` | Injection seam for SyncMonitor's "is the destination container up" probe. Tests override; production uses the real Docker check. |
| `:crash_backoff_base_ms` | `1_000` | Base backoff for the CLI auto-restart loop in `ChatAgent`. Exponential from here up to a cap. |
| `BoomLooper.PortRegistry, :port_range` | `4000..9999` | Host port range used by `PortRegistry.assign/3`. Exhaustion returns `{:error, :port_pool_exhausted}`. Keep it outside the ephemeral port range to avoid collisions with transient outbound connections. |
| `BoomLooperWeb.Endpoint, :http, :port` | `4000` | HTTP port. Env-overridable via `PORT` in `runtime.exs`. |

## Compile-time module attributes

Constants baked into modules at compile time. Change means recompile.

| Module | Attribute | Value | What it does |
|---|---|---|---|
| `BoomLooper.ChatAgent` | `@topic` | `"chat_agents"` | PubSub topic for all-agent events. |
| `BoomLooper.ChatAgent` | `@ets_table` | `:chat_agents` | ETS table for agent state snapshots. |
| `BoomLooper.ChatAgent` | `@default_crash_backoff_base_ms` | `1_000` | Default for the CLI auto-restart backoff (overridable via app config). |
| `BoomLooper.AgentLog` | `@log_version` (in ServiceManager) | `1` | ETF log schema version. Bump for structural changes; add a migrator. |
| `BoomLooper.Workspace.ServiceManager` | `@services_topic` | `"workspace_services"` | PubSub topic for cluster lifecycle events. |
| `BoomLooper.Workspace.ServiceManager` | `@status_table` | `:service_status_cache` | ETS cache of last-known service status per workspace. |
| `BoomLooper.Workspace` | `@config_dir` / `@config_file` | `".boomlooper/repo"` / `"workspace.json"` | Host-side workspace metadata location. |
| `BoomLooper.Tools.Container.Helpers` | `@max_agent_output` | `8_000` | Byte cap on tool output before truncation for the agent's context window. |
| `BoomLooper.EvalRunner` | `@default_timeout` | `2_700_000` | Eval run timeout in ms (45 min). |
| `BoomLooper.SSHServer` | `@default_port` | `0` | SSH server port (overridden by `SSH_PORT`). |

## Per-workspace config in volumes

Lives in the code volume under `.boomlooper/workspace/`. Agents write these; BoomLooper reads them.

| Path | Purpose |
|---|---|
| `.boomlooper/workspace/Dockerfile` | Workspace container image build recipe. |
| `.boomlooper/workspace/docker-compose.yml` | Compose project for the workspace. Processed by `Compose.process_agent_compose/3` — host mounts, privileged, host networking, host port pins, and external networks are rejected. See [SECURITY.md](SECURITY.md). |
| `.boomlooper/workspace/agents.log` | Append-only ETF log of agent events. Compacted at boot when it exceeds 5 MB. |

## Per-workspace metadata on host

Lives at `${BOOMLOOPER_HOME}/workspaces/<workspace_id>/` (the "compose dir") and in the repo at `.boomlooper/repo/`.

| Path | Purpose |
|---|---|
| `${BOOMLOOPER_HOME}/workspaces/<id>/docker-compose.yml` | Processed compose file written by ServiceManager for `docker compose` CLI commands. Derived from the volume copy. |
| `${BOOMLOOPER_HOME}/workspaces/<id>/.boomlooper/workspace/*` | Synced snapshot of volume-side compose + Dockerfile (via `sync_volume_to_host/2`). |
| `${BOOMLOOPER_HOME}/projects.json` | `ProjectStore` persistence — one row per project (git URL, path, volume flag). |
| `${BOOMLOOPER_HOME}/ports.json` | `PortStore` persistence — every `PortRegistry` entry (workspace / service / container_port → host_port). See [SECURITY.md § 4](SECURITY.md). |
| `${BOOMLOOPER_HOME}/secrets.json` | Secret store with optional per-secret `scope: [workspace_id | project_id]`. See [SECURITY.md](SECURITY.md). |
| `${BOOMLOOPER_HOME}/cookie` | Erlang distribution cookie for `mix boom.rpc`. |
| `${BOOMLOOPER_HOME}/ssh/ssh_host_*_key` | SSH host keys for the built-in server. |
| `<project>/.boomlooper/repo/workspace.json` | Human-facing metadata: project name, system prompt. Can be committed to git. |

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
| `:mutagen_runner` | `&System.cmd/3` | Fake that returns stubbed output (see `test/boom_looper/source/local/mutagen_test.exs`). |
| `:container_ready_check` | Real Docker probe | Fake returning `true`/`false` on demand. |
| Tool `:backend` in `ChatAgent` opts | `BoomLooper.Agent.Backend.ClaudeCode` | `BoomLooper.Agent.Backend.Fake` for unit tests that don't want a real CLI. |

## How to add a new setting

1. Decide the lifetime: **per-user** → `BOOMLOOPER_HOME` file. **per-project** → `.boomlooper/repo/workspace.json`. **per-workspace** → `.boomlooper/workspace/*` in the volume. **per-machine** → env var or app config. **per-session** → function arg / GenServer state.
2. If it's app config, give it a sensible default via `Application.get_env(:boom_looper, key, default)` — don't require the operator to set it for the happy path.
3. Add a row to this file in the right section.
4. If the setting affects a security boundary (volume scope, secrets, compose validation), also add a row to [SECURITY.md](SECURITY.md).
