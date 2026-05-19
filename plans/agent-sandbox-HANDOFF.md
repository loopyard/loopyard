# Agent Sandbox — Handoff Notes

**Branch:** `feat/agent-sandbox`
**Status:** Foundation merged on this branch + CI green. **Parked, not on main.** Resume here.

---

## Why this was parked

The implementation works and CI is green. The UX framing is the unresolved
question.

I described the user-facing flow as:

> "install Loopyard → `mix loopyard.setup` builds the image as one of
> its steps → done. Even if someone skips setup and goes straight to
> spawning an agent, `AgentSandbox.ensure_running` lazy-builds on the
> first call."

The user pushed back hard: *"I don't want people to have to run a bunch
of fucking commands."* They want the sandbox image build to be
**invisible** — users should never have to think about it, not even as
a step inside `mix loopyard.setup`.

The likely right answer (not implemented yet): **build the image
asynchronously at app boot.** When the Loopyard application starts
(via `mix loopyard.server`), spawn a background `Task` that checks
`AgentSandbox.image_present?/0` and builds if missing. By the time the
user spawns their first agent, the image is ready. If it isn't,
`ensure_running/3`'s lazy build already covers it as a backstop.

Concretely: add a child to `Loopyard.Application.start/2` that does:

```elixir
# Loopyard.Application or a small wrapper module
Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
  unless Loopyard.AgentSandbox.image_present?() do
    case Loopyard.AgentSandbox.build_image() do
      :ok -> Logger.info("[Sandbox] image ready")
      {:error, reason} -> Logger.warning("[Sandbox] background build failed: #{inspect(reason)} — will lazy-build on first agent spawn")
    end
  end
end)
```

And **revert the `mix loopyard.setup` step that builds the image** —
delete that whole block from `lib/mix/tasks/loopyard.setup.ex`. It
shouldn't be a user-visible thing.

---

## What's on this branch (5 commits past `main` at `8c37f31`)

| Commit | What |
|---|---|
| `fbc0406` | Plan doc: `plans/agent-shell-container.md` — the per-agent sandbox spec |
| `13c9494` | Foundation: `priv/agent-sandbox/Dockerfile`, `Loopyard.AgentSandbox` module, `mix loopyard.sandbox.build` task, unit + `:docker` integration tests, CONFIG.md entries. Deletes dead `priv/workspace-base/`. |
| `8b48b24` | CI: build the sandbox image in the docker-e2e job before tests run |
| `bf35a88` | Auto-build: setup step + lazy fallback in `ensure_running/3`. **THIS is the one the user objected to (specifically the setup step).** |
| `52b694c` | Format compat for Elixir 1.18/1.19 disagreement on a multi-line `or` chain |

CI is green on `52b694c` — all three jobs (test, quality, docker-e2e).

---

## Design — what we landed on (see plans/agent-shell-container.md for the full spec)

After a lot of design churn captured in the chat, the final shape:

- **Each agent gets its own Loopyard-owned sandbox container.** Named
  `loopyard-<workspace_id>-agent-<agent_id>`. Image
  `loopyard/agent-sandbox:0.1.0` (alpine + git + ripgrep + jq +
  coreutils + findutils + bash + curl + rsync + ca-certificates +
  github-cli + openssh-client). Mounted on the workspace's code volume.
  `--network none`, 512m memory cap, `sleep infinity`.
- **All file/inspection tools route to this container** by `agent_id`.
  Single backend, no two-tier resolution, no fallback path. Compile-time
  deterministic.
- **For project commands** (`mix test`, `bin/rails`, `npm install`,
  etc.), the agent uses the existing `docker_compose exec <service>
  <cmd>` tool as the deliberate cross-container escape. The sandbox
  intentionally does NOT have language toolchains — that's the user's
  service's job.
- **The structural insight that drove the shape:** Loopyard's product
  promise is "sandboxed agents, no setup required." Delegating the
  agent's runtime to the user's compose `workspace` service inverts
  that promise. The sandbox should be Loopyard's, not user-defined.

### Key design alternatives we considered and rejected

| Model | Why we didn't pick it |
|---|---|
| Two-tier `resolve_container` (user service if up, sandbox if not) | "Subtle bugs from divergent paths" |
| Split by tool semantics (introspection→sandbox, exec→user) | Same divergent-paths problem |
| Per-agent container lock + escape hatch for cross-container work | Setup agent crossing into dev felt arbitrary |
| Per-player containers (one per human session) | Breaks multiplayer; identity not built yet |
| Auto-inject default `workspace` service into user's compose | Magic into user's compose; can't override their broken definition |
| Require users to define a `console` service | Pushes sandbox responsibility back to user — inverts product promise |

The conversation that led here was long. The final landing was "per-agent
sandbox" + "explicit `docker_compose exec` for cross-container work."

---

## What works on this branch

Foundation only — no agents actually route to the sandbox yet.

- `priv/agent-sandbox/Dockerfile` builds locally and in CI's docker-e2e job
- `Loopyard.AgentSandbox` module with `container_name/2`, `image_name/0`,
  `ensure_running/3` (idempotent, lazy-builds on missing image), `stop/2`,
  `running?/2`, `build_image/0`, `image_present?/0`
- `mix loopyard.sandbox.build` task (delegates to `AgentSandbox.build_image`)
- 5 unit tests + 6 `:docker`-tagged integration tests, all green on CI

Behavior is unchanged. The existing `loopyard-<ws>-workspace-1`
resolution path is exactly as it was. Nothing routes to the sandbox
container yet — the module exists in isolation.

---

## What's left to do (in order)

### Immediate (the UX correction)

1. **Revert the `mix loopyard.setup` "Agent sandbox image" step**
   (in `bf35a88`). The user explicitly objected to this.
2. **Add async image build at app boot** instead — see the code snippet
   at the top of this doc. Goes in `Loopyard.Application.start/2`,
   probably right after `Loopyard.TaskSupervisor` is in the children
   list.
3. Keep the lazy-build in `ensure_running/3` as the backstop (it's
   already there).

### Then: PR 1.5 — wire the sandbox into the agent boot saga

1. New saga step in `Loopyard.AgentBoot.boot/3` — `:ensure_sandbox`
   that calls `AgentSandbox.ensure_running(workspace_id, agent_id,
   volume_name)`. Insert between `:load_config` and `:ensure_services`.
2. Behind a feature flag — `Application.get_env(:loopyard,
   :agent_sandbox_enabled, false)`. Step is a no-op when off.
3. Saga rollback — on later step failure, stop the sandbox container.
4. Wire `Workspace.Destructor` to remove agent sandbox containers
   alongside the rest of the workspace's resources.
5. Tests: saga step success + rollback, destructor cleanup.

### Then: PR 2 — flip the routing

This is the breaking change. Run it as its own session with conscious comms.

1. Rewrite `Helpers.resolve_container/1` to return
   `AgentSandbox.container_name(workspace_id, agent_id)` instead of
   `loopyard-<ws>-workspace-1`. This requires threading `agent_id`
   through to every tool — today some tools have it (they take it as
   a param), others derive the container from less specific context.
   The `exec_in`-route tools all take `agent_id` already (see how
   `Helpers.resolve_container/1` is called from `lib/loopyard/tools/container/exec.ex` etc.).
2. Re-key `VolumeIO` by `agent_id` (today it's keyed by volume name).
   This changes the calling convention for `read_file`/`write_file`/`edit`.
3. Update the agent system prompt in `lib/loopyard/chat_agent/prompt.ex`
   — replace "Workspace container: loopyard-<ws>-workspace-1" with
   "Your sandbox: loopyard-<ws>-agent-<id>. For project commands
   (`mix`, `bin/rails`, `npm`), use `docker_compose exec <service>
   <cmd>` — the sandbox doesn't have language toolchains."
4. Drop `VolumeIO`'s `docker run --rm alpine` fallback branch.
5. Flip `:agent_sandbox_enabled` default to true.
6. Update CHANGELOG with migration note: agents now run in Loopyard
   sandboxes; the user's `workspace` compose service is no longer
   targeted by default — they reach it via `docker_compose exec
   workspace <cmd>` when needed.

---

## How to resume

```bash
git checkout feat/agent-sandbox

# Read these in order:
# 1. plans/agent-shell-container.md  — the full design spec
# 2. plans/agent-sandbox-HANDOFF.md   — this file, the chat-context bridge
# 3. lib/loopyard/agent_sandbox.ex    — the foundation that's already built
# 4. test/loopyard/agent_sandbox_test.exs  — what's tested + what's :docker-tagged

# To resume coding:
# Start with the UX correction (above) before anything else.
```

If we decide the per-agent-sandbox design is wrong after all, the
five commits on this branch are easy to discard — nothing on `main`
depends on them.

---

## Things to NOT forget when resuming

- **Don't add user-facing commands.** The user's pain point is "no
  more `mix do this then mix do that`." Image build is invisible.
- **The `RestartControllerTest` and `wait_for_workspace_ready` test
  failures we saw in CI were pre-existing flakes** — not regressions
  from this work. Timing-dependent supervisor races. Out of scope.
- **CI is on Elixir 1.18 / OTP 27** (reverted from a brief 1.19/28
  experiment that broke supervisor timing — see `8c37f31`'s commit
  message). xref cycle threshold is at 40 to absorb 1.18's
  deduplication artifacts.
- **`mix xref --format cycles`** on this branch reports 1 cycle (on
  1.19) but CI sees ~35 (1.18 doesn't dedupe). Don't be alarmed.
- **The user has 5 `mix phx.server` BEAMs running on their box** —
  be careful with anything that touches global Docker state during
  local testing. Don't kill processes.
