# Per-Agent Sandbox Container — Loopyard owns the agent's runtime

## Why

Loopyard's core product promise is "give me a sandboxed agent and I
don't have to set anything up first." Today that promise is half-true:
agents run in a container, but the container is *the user's compose
`workspace` service* — meaning the agent's runtime depends on the
user's compose being well-formed and running. When it isn't (fresh
clone, broken compose, services intentionally stopped), the agent is
crippled in inconsistent ways:

- **`VolumeIO`-routed tools** (`read_file`, `write_file`, `edit`,
  `multi_edit`, `volumes`) have a `docker run --rm alpine` fallback.
  They work degraded — just slow.
- **`exec_in`-routed tools** (`exec`, `grep`, `tree`, `glob`,
  `file_info`, `ports`, `inspect_env`) have no fallback. They just fail.

Three user-visible failure modes:

1. **Fresh clone.** Workspace exists, volume populated, no compose
   yet. Agent boots but can't `tree`, `grep`, `exec ls`. Half-blind.
2. **Broken compose.** User's `docker-compose.yml` or their Dockerfile
   doesn't build. The agent that was supposed to *help diagnose* can't
   run a single shell command.
3. **Services stopped.** User stops the cluster to reclaim resources.
   Comes back later wanting to look at code — agent can't.

The deeper structural problem: **Loopyard delegates its own sandbox to
the user.** If the user's compose service isn't healthy, Loopyard's
agent isn't healthy. That inverts the product promise — users came to
Loopyard *so they wouldn't have to manage their own dev environment*.

## What we're building

**Each agent gets its own Loopyard-owned sandbox container.** The
container is the agent's runtime. It always exists when the agent is
alive. Every introspection tool routes to it deterministically by
`agent_id`. No two-tier lookup, no fallback path, no "is X running?"
branch.

For project commands that need the user's toolchain (`mix test`,
`bin/rails db:migrate`, `npm install`), the agent uses the existing
`docker_compose exec <service> <cmd>` tool — explicit cross-container
escape into user services when needed.

**Scope:**
- Loopyard-owned sandbox image (`loopyard/agent-sandbox`).
- One container per agent, named `loopyard-<workspace_id>-agent-<agent_id>`.
- Lifecycle wired into the agent (boot/stop/crash/reap).
- Tool resolution rewritten: `Helpers.resolve_container/1` returns the
  agent's own sandbox, period. Both `Docker.exec_in` and
  `VolumeIO` flows converge on this single resolution.
- `VolumeIO`'s `docker run --rm alpine` fallback gets removed once
  the sandbox is always available.

**Non-goals:**
- Replacing the user's compose services for build/test work. Their
  app, postgres, redis stay defined by their compose. The sandbox is
  Loopyard's; their services are theirs.
- Putting language toolchains in the sandbox. The sandbox is for
  file ops, git, grep, basic shell. Language work goes through
  `docker_compose exec <service>`.
- Persistent state across container rebuilds. The volume is the
  durable thing; the sandbox is disposable.
- Sharing sandboxes across agents. Each agent has its own. Multiplayer
  still works because the *volume* is shared — agents see each other's
  file edits even though their runtimes are isolated.

---

## Current state — what we're replacing

### Two divergent surfaces today

**`Docker.exec_in/3`** — `lib/loopyard/docker.ex:92`. Direct
`docker exec <name> <cmd>`. No fallback. Used by `exec`, `grep`,
`glob`, `tree`, `file_info`, `inspect_env`, `ports`. Container
resolution: `Helpers.resolve_container/1` returns
`loopyard-<workspace_id>-workspace-1` — the user's compose
`workspace` service.

**`VolumeIO`** — `lib/loopyard/volume_io.ex`. Two-path: try
`exec_in` against the workspace container, fall back to
`docker run --rm -v vol:/workspace alpine <cmd>`. Used by
`read_file`, `write_file`, `edit`, `multi_edit`, `volumes`.

These collapse into one surface after this work: every tool goes
through `Helpers.resolve_container/1` which returns the agent's
sandbox.

### Compose lifecycle tools stay

`docker_compose`, `app_url`, `inspect_service`, `probe_http`,
`workspace_info`, `service_containers` — these operate on the user's
compose cluster and are unchanged. `docker_compose exec` becomes the
official "reach the user's services" path.

---

## Design

### Image

`docker/agent-sandbox/Dockerfile`:

```dockerfile
FROM alpine:3.19
RUN apk add --no-cache git ripgrep jq coreutils findutils bash ca-certificates
WORKDIR /workspace
CMD ["sleep", "infinity"]
```

Tagged `loopyard/agent-sandbox:<version>`. Built by a new
`mix loopyard.sandbox.build` task and pulled-or-built as part of
`mix loopyard.setup`. Version pin moves only when the Dockerfile
changes; pinned version recorded in `docs/CONFIG.md`.

### Container

- **Name:** `loopyard-<workspace_id>-agent-<agent_id>`. One per agent.
- **Image:** `loopyard/agent-sandbox:<version>`.
- **Mounts:** the workspace's code volume at `/workspace`. Nothing
  else. No host filesystem. No additional bind mounts.
- **Network:** `--network none`. The sandbox does file I/O and local
  shell work — never makes outbound HTTP calls. Anything that needs
  network (git push, package install) goes through `docker_compose
  exec` into a properly-networked service.
- **Other run args:** `--init`, `--memory=512m`, `--label
  loopyard.sandbox=true`, `--label loopyard.agent_id=<id>`, `--label
  loopyard.workspace_id=<ws>`, command `sleep infinity`.

### Lifecycle

The sandbox container is owned by the agent. Two natural integration
points:

**Option A:** Extend `Loopyard.AgentBoot`'s saga. Today step 2 is
`:ensure_services` which kicks off the user's compose-up. Add a sibling
step `:ensure_sandbox` (or split: `:ensure_sandbox` always runs first,
`:ensure_services` becomes optional / non-blocking) that brings up the
agent's sandbox container.

**Option B:** New `Loopyard.AgentSandbox` module the ChatAgent calls
directly on init/terminate. `ChatAgent.init` → `AgentSandbox.start`,
`ChatAgent.terminate` → `AgentSandbox.stop`. Sandbox lifecycle bound
tightly to GenServer lifecycle.

Recommended: **Option A** — fits the existing saga model, gets
rollback for free if the next step fails, and the sandbox becomes an
explicit boot step the user can see in the UI alongside compose
startup.

Rollback / cleanup:
- Agent normal stop (user clicks Stop) → sandbox container stopped + removed.
- Agent crash → existing crash-recovery path. On re-spawn, the saga
  re-ensures the sandbox (idempotent: if it's still there from before
  the crash, reuse it).
- Agent reaped (idle past `agent_idle_reap_hours`) → sandbox stopped.
- Workspace destroyed → `Workspace.Destructor` cleans up any
  agent sandboxes alongside other workspace resources.
- Server restart → on workspace boot, ServiceManager replays the
  agent log; each restored agent's saga re-runs `:ensure_sandbox`.

### Tool resolution

Single function, single rule:

```elixir
def resolve_container(agent_id) do
  workspace_id = lookup_workspace_id(agent_id)
  "loopyard-#{workspace_id}-agent-#{agent_id}"
end
```

No conditionals. No two-tier. No probing whether a container is
running — the saga guarantees it before the agent transitions to
`:idle`.

`Helpers.resolve_container/1` returns this name. Every `exec_in`-using
tool gets it. `VolumeIO.find_container_for_volume/1` is replaced with
"look up the agent that's calling and return its container name" —
which requires threading `agent_id` through `VolumeIO`. (Today
`VolumeIO` is keyed by volume name; the new version is keyed by
calling agent's container name.)

### What the agent sees

The system prompt's `base_prompt` (`lib/loopyard/chat_agent/prompt.ex`)
gets updated. Where today it says:

> Workspace container: loopyard-<ws>-workspace-1.

After:

> Your sandbox container: loopyard-<ws>-agent-<id>. All tool calls
> run inside it. The sandbox has git, ripgrep, jq, and basic Unix
> utilities — but NOT your project's language toolchain.
>
> For project commands (`mix test`, `bin/rails`, `npm install`, etc.),
> use `docker_compose exec <service> <cmd>` to reach the running
> service container that has your toolchain.

Plus the existing "use the right MCP tool for X" patterns the agent
already follows.

---

## Edge cases

### Multiple agents in one workspace

Each gets its own sandbox container. All mount the same code volume,
so they see each other's file edits (multiplayer property). Agent A's
`/tmp` scratch, env vars, installed packages — invisible to Agent B.
Resource cost: N agents = N containers × ~10-30MB. Bounded by active
agent count.

### Agent crashes mid-tool-call

Existing crash-recovery path kicks in. ChatAgent restarts under
RestartController supervision. Sandbox container survives (it's
`sleep infinity` — not coupled to the BEAM process). On restart, the
saga's idempotent `:ensure_sandbox` finds the container still running
and reuses it.

### Sandbox container crashes

`AgentSandbox.start` is idempotent on the running side too. If a tool
call discovers the container is gone (exec returns "no such
container"), the agent transitions to a `:sandbox_recovering` state,
re-runs the saga step, then retries the tool. User sees a one-second
blip, no manual intervention needed.

### Volume doesn't exist (workspace registered but not seeded)

Sandbox container fails to start at the `-v` mount step. Saga step
fails with a clear error → agent transitions to `:boot_failed` with
the existing WHY/CONSEQUENCE/ACTION error pattern: "Workspace volume
not initialized — run Setup to clone and seed."

### Image hasn't been pulled

`docker run loopyard/agent-sandbox` fails with "image not found." Saga
catches the error, attempts `docker pull` (or `docker build` from the
local Dockerfile if registry is unreachable), retries once. If still
failing, surfaces a clear "Loopyard sandbox image unavailable — run
`mix loopyard.setup`" error.

### User's compose service is also called `workspace`

No collision — sandbox name is `loopyard-<ws>-agent-<id>`, compose
service name is `loopyard-<ws>-workspace-1`. Different namespaces.

### Setup agent specifically

Setup agent is the one that bootstraps a project. Today it runs in
the workspace service it's about to define — circular. After this
change: Setup agent runs in its own sandbox (same as any other agent).
From there it can read the code, write the Dockerfile and compose,
and call `docker_compose up` to bring the user's cluster up. No more
circular dependency.

---

## Implementation order

Two PRs, the second contains the breaking change:

### PR 1 — Foundation (this session's scope)

Build the primitive without rerouting tools. Existing behavior
preserved; new infrastructure ready to be wired up in PR 2.

1. `docker/agent-sandbox/Dockerfile` + image build infrastructure
   (`mix loopyard.sandbox.build`).
2. `Loopyard.AgentSandbox` module — `start/2`, `stop/1`, `ensure/2`
   (idempotent), `container_name/2`. Uses `Loopyard.Docker` directly.
3. Wire into `AgentBoot` saga as a new `:ensure_sandbox` step,
   **behind a feature flag** (`Application.get_env(:loopyard,
   :agent_sandbox_enabled, false)`). When the flag is off, this step
   is a no-op; the agent runs against the existing workspace service
   as today. When on, the sandbox is brought up.
4. Add the sandbox to `Workspace.Destructor`'s cleanup sequence.
5. Tests — unit tests for `AgentSandbox` (mocked Docker calls);
   `:docker`-tagged integration tests for actual container
   start/stop/recovery.
6. Docs — `CONFIG.md` gets the new flag + image version pin.

### PR 2 — Migration

1. `Helpers.resolve_container/1` rewritten to return the agent's
   sandbox name.
2. `VolumeIO` re-keyed by `agent_id`, alpine-fallback branch deleted.
3. `base_prompt` updated to teach the agent: sandbox has basic tools,
   `docker_compose exec <service>` for project work.
4. Feature flag default flipped to `true`.
5. Existing tests updated to expect sandbox routing.
6. Migration note in CHANGELOG: agents now run in Loopyard sandboxes;
   the user's `workspace` compose service (if defined) is no longer
   targeted by default — they reach it via `docker_compose exec
   workspace <cmd>` when needed.

### PR 3 (optional, later)

Remove the feature flag. Sandbox is now load-bearing.

---

## Open questions

- **Memory cap.** `--memory=512m` is a guess. `ripgrep` over a 10GB
  repo could push higher. Validate empirically on the largest internal
  repo before settling. Lower bound is "enough for the agent's
  inspection tools without OOM"; upper bound is "doesn't add up to
  unreasonable RAM under high agent counts."
- **Should `inspect_env` and `inspect_service` keep targeting the
  user's services?** They semantically only make sense there — the
  sandbox has no env to inspect, no service identity. Keep them on
  the user-compose path; they're already structured around `docker
  inspect`, not `exec_in`.
- **Pre-warmed pool?** Spinning up a new sandbox per agent takes ~1-2s
  (image is local, just a start). Probably not worth a pool. Worth
  revisiting if agent-spawn latency becomes user-visible.

---

## Code rules this plan upholds

- **CODE_RULES § "One source of truth per domain"** — single
  resolution function returns the agent's sandbox; no divergent
  paths.
- **CODE_RULES § "Operations must be idempotent"** —
  `AgentSandbox.ensure/2` is idempotent on container state.
- **CODE_RULES § "ETS tables are owned by StateKeeper"** —
  any tracking tables `AgentSandbox` needs go through StateKeeper.
- **CODE_RULES § "Every Task must be supervised"** — image-pull tasks
  go through `Loopyard.TaskSupervisor`.
- **docs/SECURITY.md** — per-agent isolation, network-none, no host
  mounts. Same boundary contract as existing workspace containers.

## Docs to update when this ships

- `docs/ARCHITECTURE.md` — new module + the "one sandbox per agent"
  claim; the boot saga's `:ensure_sandbox` step.
- `docs/SECURITY.md` — confirm the sandbox's mount + network posture.
- `docs/CONFIG.md` — `:agent_sandbox_enabled`, pinned sandbox image
  version, memory cap.
- `docs/CODE_RULES.md` — drop the dual-path `VolumeIO` guidance;
  record "every tool resolves to the agent's own sandbox."
- `CLAUDE.md` — sharpen "agents run code inside Docker containers" to
  "each agent runs inside its own Loopyard-managed sandbox; user
  compose defines auxiliary services."
