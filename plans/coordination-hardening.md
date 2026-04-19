# Coordination Hardening

Goal: eliminate entire **classes** of bugs from the core compose + agent coordination layer, not the individual instances. After this plan lands, the communication and state layers both have compile-time contracts, observable timelines, and structural guarantees of eventual consistency.

## The bug classes we're eliminating

Each of these is a real bug shipped this sprint:

1. **State drift** — GenServer state, ETS, LV assigns, and the persistence log hold overlapping copies. They disagree under race, partial failure, or resume paths. _(Sleepy agent, zeroed Claude panel.)_
2. **Silent broadcast drops** — messages land in `handle_info(_msg, _)`. No compiler or runtime signal. _(Workspace LV ignoring `:chat_agent_resumed`.)_
3. **Stuck-forever states** — `:booting`, `:starting`, `:crashed` have no structural guarantee of eventual transition. _(Workspace pinned at Starting after compose failure.)_
4. **Reality-vs-cache divergence** — Docker truth is external; our mirror can drift silently. _(Observer cache going stale when the event stream stops.)_
5. **Broadcast slop** — raw `Phoenix.PubSub.broadcast/3` called from ~30 sites with tuple-typed payloads. No contract between producer and consumer. _(Any future event-shape change breaks subscribers invisibly.)_
6. **Partial-success states** — multi-step operations (start workspace, boot agent) fail midway and leave inconsistent state that relies on reconcilers to clean up. _(Missing Dockerfile → compose fails → workspace half-registered, half-supervised.)_
7. **Orphan resources** — Docker containers, port bindings, streaming tasks, CLI subprocesses survive their Elixir owner. Resource cleanup relies on scattered `trap_exit` / `terminate/2` that's easy to miss. _(OS processes that outlive the agent.)_
8. **Retry-storm amplification** — one external dependency failure (Docker daemon, Claude API) triggers uncoordinated retries across every caller. No circuit breaker. _(Colima crash → 10 workspaces each backing off + retrying simultaneously.)_
9. **Unbounded recovery time** — every boot replays the full log from day one. Grows linearly with uptime. At some point replay times out and agents silently don't restore.
10. **Mid-operation crashes leave unrecoverable state** — saga running, BEAM dies, reboot. No record of how far we got, so we either restart from scratch (possibly creating duplicates) or manually diagnose.
11. **Silent crash loops** — actor crashes and restarts dozens of times per hour with no surface signal. Logs are noisy but no alarm. _(Seen: 26 resumes/hour on one agent.)_
12. **Upstream outage looks like our bug** — Docker daemon down → half the UI blank → users report "BoomLooper broken" when actually it's Colima. No degradation markers.
13. **Unclean shutdown compounds silently** — power loss or `kill -9` leaves half-written log / orphan containers / uncommitted saga. Next boot acts normal, corruption compounds.

## The seven design moves

Ordered so each stacks on the last. The first three harden communication; the next three harden state and liveness; the last is observability that pairs with all of them.

### 1. Pure transition function per actor

Every state-machine actor (`ChatAgent`, `ServiceManager`, `WorkspaceGroup`, `SyncMonitor`, `Cluster`) gets a total transition function:

```elixir
ChatAgent.Transitions.step(state, event) ::
  {:ok, new_state, side_effects :: [term]} | {:error, reason}
```

`side_effects` is a list of `{:broadcast, event}`, `{:persist, data}`, `{:schedule, timer}` tuples. The function is pure and total over `{state, event}` pairs. Adding a new event without handling it is a non-exhaustive-match warning.

GenServer handlers become thin dispatchers that apply side effects uniformly — one codepath for every transition. You cannot broadcast without writing ETS, or write ETS without persisting, because the wrapper runs all of them from the same return value.

**Kills:** silent drops at the producer. Opens move 4.

### 2. Publisher modules + banned raw broadcast

One publisher module per topic:

```elixir
defmodule BoomLooper.Events.ChatAgent do
  defmodule Resumed       do defstruct [:id, :summary] end
  defmodule Crashed       do defstruct [:id, :reason]  end
  defmodule StatusChanged do defstruct [:id, :status]  end

  def publish(%Resumed{} = e),       do: bcast(e)
  def publish(%Crashed{} = e),       do: bcast(e)
  def publish(%StatusChanged{} = e), do: bcast(e)

  defp bcast(e), do: Phoenix.PubSub.broadcast(BoomLooper.PubSub, "chat_agents", e)
end
```

Add a CI test that greps `lib/` for `Phoenix.PubSub.broadcast` outside approved publisher modules — fail.

**Kills:** broadcast slop. Typo'd topics, malformed payloads, shape drift. The struct name becomes the universal identifier; grepping `Resumed` finds every producer and consumer by name.

### 3. Strict subscriber behaviour

Each LV that subscribes declares:

```elixir
@behaviour BoomLooper.Events.ChatAgent.Subscriber
```

The behaviour has `@callback on_resumed(Resumed.t(), socket)`, one per event. Missing callback → compile warning via `@impl`. A generated `handle_info(%Struct{} = e, socket)` dispatcher routes to the right callback.

The current static coverage test stays as a belt-and-suspenders check, but `@behaviour` is the primary contract.

**Kills:** silent drops at the consumer. Adding a new event forces every subscriber to implement it or explicitly opt out.

### 4. Single state owner — ETS and log as projections

Today GenServer state, ETS summary, and the log are three independent copies kept in sync by hand. Every sync miss is a bug.

Introduce `BoomLooper.OwnedState`:

```elixir
OwnedState.put(owner_pid, new_state, projections: [:ets, :log, :broadcast])
```

One atomic call writes GenServer state, ETS, the log, and fires broadcasts from the transition function's `side_effects`. No other code writes to `:chat_agents` ETS. No other code appends to `agents.log`.

**Kills:** state drift class entirely. Drift becomes structurally impossible, not avoided by convention.

### 5. Every non-terminal state has a deadline

State machines already carry `entered_at`. We just aren't enforcing bounds.

Add `BoomLooper.Deadlines` GenServer. On app boot, reads each state machine's `@max_durations`. Every 10s scans ETS for `now - entered_at > max_duration` and emits a forced-transition event. E.g. `:booting` past 5 min → `%BootTimedOut{id: id}` event, which the pure transition function must handle (move 1 makes this a compile check).

**Kills:** stuck-forever states. The scanner is the structural guarantee, not a retry we remember to add.

### 6. Reconciler per external dependency

Docker has a 30s reconciler (shipped this sprint). Extend the pattern:

- `Workspace.Reconciler` — every 30s, diffs `WorkspaceRegistry` entries against the supervisor tree.
- `Agent.Reconciler` — every 30s, diffs `:chat_agents` ETS summaries against `ChatAgentRegistry` alive pids.

Drift emits `%Reconciled{kind, before, after, corrected}` to a reconciliation topic. Grafana / LiveDashboard shows drift rate.

**Kills:** reality-vs-cache divergence. The periodic diff is the structural assumption, not a fallback.

### 7a. Saga / rollback for multi-step operations

"Start a workspace" is ~5 steps: start supervisor → start ServiceManager → register → compose up → broadcast. Any step failing today leaves inconsistent partial state that the reconciler (#6) has to clean up. That's recovery, not prevention.

Design: a `BoomLooper.Saga` module where each step declares its own rollback. On any failure, rollback chain runs in reverse. No half-started workspace ever exists.

```elixir
Saga.run([
  {:start_supervisor, rollback: &stop_supervisor/1},
  {:start_service_manager, rollback: &stop_service_manager/1},
  {:register_workspace, rollback: &deregister_workspace/1},
  {:compose_up, rollback: &compose_down/1}
])
```

**Kills:** partial-success state that the reconciler has to interpret after the fact. Start-workspace flows either fully succeed or fully revert. This class is distinct from reality-vs-cache drift — it's about our own multi-step transactions.

**Observable in `/system/sagas`:** recent saga runs, which step failed, whether rollback succeeded. When a rollback fails (the scary case), red alert.

### 7b. Explicit resource ownership

Containers, port bindings, volumes, streaming tasks, CLI subprocesses — every one of these is a resource that belongs to some Elixir process and should die when the owner dies. Today it's scattered: `Process.link` here, `trap_exit` there, a `terminate/2` over there. Easy to forget one and leak.

Design: `BoomLooper.ResourceOwner` behaviour. An owner declares `resources/1` returning `[{kind, id}]`. A supervised janitor monitors every owner and, on DOWN, releases the listed resources (kill container, unbind port, cancel stream). Orphans become structurally rare rather than "we hope `terminate/2` ran."

**Kills:** orphan resources class. Workspace destroyed → containers gone, ports freed, no guessing whether cleanup fired.

**Observable in `/system/orphans`:** resources in Docker/OS without a matching live owner. Even after cleanup is automatic, surfacing leaks is how we catch bugs in the ownership declarations.

### 7c. Property-based tests for every pure transition function

Once move #1 (pure transitions) lands, every state-machine actor has a total function `step(state, event) :: result`. This is the ideal target for StreamData generators.

Design: for each actor, generate all `{state, event}` pairs and assert invariants:
- Terminal states stay terminal (no event reaches `:destroyed` → anything else)
- No transition bypasses required side effects (e.g. `:booting → :idle` must include a `{:broadcast, StatusChanged}` side effect)
- `entered_at` is monotonic across transitions
- Deadline-forced transitions have idempotent targets (force-timeout twice → still OK)

**Kills:** the "new event I forgot to handle in some corner case" class. Effectively free once move #1 is done — property tests are ~50 lines per actor.

**Observable in CI:** the property tests themselves. Shrink counterexamples get logged and regression-tested automatically.

### 7d. Circuit breakers for every external dependency

Docker, Claude API, Mutagen sync, GitHub API — each has ad-hoc backoff scattered through its caller. A single crashing daemon can cause retry-storm across dozens of agents/workspaces.

Design: `BoomLooper.CircuitBreaker` wrapping each external call. States: `:closed` (normal), `:open` (stop trying), `:half_open` (probe). Thresholds configurable per breaker. `mix boom.rpc 'CircuitBreaker.status()'` shows which are tripped.

**Kills:** retry-storm amplification. One Docker daemon outage no longer burns CPU on 10 workspaces × exponential-backoff × infinite retry.

**Observable in `/system/breakers`:** state per breaker, trip count, last trip timestamp, current fail-rate. Also a telemetry event on every state transition.

### 7. Dev-mode event tap + telemetry on every publish

`BoomLooper.Events.Tap` — supervised GenServer subscribed to every topic, writes the last 1000 events to an ETS ring buffer with timestamps. `EventTap.recent("chat_agents", 30_seconds)` returns a timeline. Attached in `:dev` and `:test` only.

Publisher modules emit `:telemetry.execute([:boom_looper, :events, :publish], %{size: byte_size(bin)}, %{topic: t, event: mod})`. Free LiveDashboard, free metrics, assertable-in-tests (`assert_receive_telemetry/1`).

**Kills:** "we couldn't reproduce the race." Next sleepy-agent report, you read the tape.

## Recovery axis

The moves above prevent bad states. These ensure the system heals when they happen anyway — because crashes, corruption, and operator errors are inevitable.

### 8. Checkpoint-based recovery

Today log replay is O(history). A workspace running for months takes seconds to reload and will eventually exceed timeouts. Compaction exists but runs ad-hoc.

Design: every N minutes (or M log records), the state owner writes a **snapshot** to disk and truncates the log. On boot: load snapshot, replay log-since-snapshot. Recovery time becomes bounded and predictable, independent of uptime.

Snapshot format: the current summary map, serialized. Log entries after the snapshot replay on top. If snapshot is corrupt, fall back to the previous snapshot — always keep two.

**Kills:** "recovery time grows unboundedly with uptime." Also catches log corruption: a snapshot won't load → fall back + log anomaly, rather than the current "replay fails partway, silently drop agents."

**Observable in `/system/recovery`:** snapshot size + age per actor, last recovery time on boot, whether fallback was used.

### 9. Saga journal with resume-on-boot

Sagas (#7a) solve partial-success during a run. They don't solve "BEAM crashed mid-saga." A saga that started `compose up`, wrote the ETS entry, then the node died — on reboot, is the saga done? Abandoned? Reversed?

Design: each saga step commits its progress to a disk journal before execution. On boot, scan the journal for incomplete sagas. For each: either resume from the last completed step (if idempotent and external state confirms) or run rollback-from-here. No saga is ever abandoned.

**Kills:** "BEAM crashed mid-workspace-start, now there's half-state that survives reboot." Sagas become durable transactions.

**Observable in `/system/sagas`:** in-flight saga count, last resumed saga on boot, any saga that failed rollback (red alert — needs manual).

### 10. Quarantine for crash-looping actors

We already saw an agent restart 26 times in an hour with no surface signal. Supervisors happily honor `restart: :transient` until heat death.

Design: the supervisor (or a sibling monitor) tracks restart frequency per child. After N crashes in T seconds (say 5 in 60), the child moves to `:quarantined` — stopped, marked unhealthy, broadcast to operators. The trigger message (if identifiable) is captured for forensics. Manual restart via UI or `mix boom.rpc`.

For agents specifically: if the same event class keeps crashing the GenServer (poisoned-message shape), the pure transition function (move #1) can hash the event and refuse to apply it if the same hash crashed us in the last T seconds. Event goes to a `:quarantined_events` ETS slot for inspection. Actor survives.

**Kills:** restart-storm burning CPU, API tokens, and log space. Poisoned messages no longer drag the whole actor down.

**Observable in `/system/quarantine`:** list of quarantined actors + reason, list of quarantined events + trigger. One-click un-quarantine for operators.

### 11. Graceful degradation markers

Today when Docker dies, half the UI shows blank. Other half silently retries. No clear "this feature is degraded, this one still works."

Design: each subsystem has a public `health/0` returning `:healthy | {:degraded, reason} | {:down, reason}`. Aggregated at `/system/health` as a component tree. Circuit breakers (#7d) feed directly into this — breaker open → feature degraded. The UI reads the tree and renders banners / disables buttons accordingly: "Docker daemon unreachable; container operations queued." Users know exactly what works and what doesn't.

**Kills:** the "is this broken or is the UI just slow?" experience during upstream outages. Partial functionality stays useful instead of looking fully broken.

**Observable in `/system/health`:** tree of components with status, last state change, dependencies between them (ChatAgent degraded → because Claude CLI breaker open → because N timeouts in 30s).

### 12. Unclean-shutdown safe mode

If BEAM exits cleanly, we write a `clean_shutdown` marker. If that marker is missing on boot, prior shutdown was crash/kill/power-loss. In that case, enter **safe mode**: run all reconcilers before accepting new work, refuse to start new workspaces/agents until the reconcile passes, surface a "Recovering…" banner with a log of what got fixed.

This is cheap to build (~50 lines) and is the difference between "boot and hope" and "boot and verify." Catches the compounding-corruption case: if a prior crash left orphan containers AND the reconciler has a bug, we don't just paper over it — we know recovery isn't clean.

**Kills:** "prior crash left state we never noticed, new work compounded the corruption." Operator sees recovery status before using the system.

**Observable in `/system/health`:** bold banner during safe mode, recovery log (what reconcilers corrected), transition to normal only when everything's green.

## Observability in `/system`

Every move ships with a surface on `/system` so the guarantee is visible, not just structural. If we can't see it, we can't trust it.

| Move | Surface | What it shows |
|------|---------|---------------|
| #1 pure transitions | `/system/actors` | every state-machine actor: current state, `entered_at`, last 10 transitions, events-per-minute |
| #2 publisher modules | `/system/events` | per-topic broadcast rate, per-event count, last-5-minutes histogram |
| #3 subscriber behaviours | `/system/events` → topic detail | subscribers per topic, any LV compile-warned for missing callbacks |
| #4 OwnedState | `/system/actors` → actor detail | ETS last-write vs log last-append vs last-broadcast timestamps — red light if they diverge |
| #5 deadlines | `/system/deadlines` | currently-near-deadline states, forced-transition history, false-positive rate |
| #6 reconcilers | `/system/reconcilers` | last run per reconciler, drift rate, last 10 drift events with before/after |
| #7 tap + telemetry | `/system/events` | the page IS the tap — live timeline of every broadcast on every topic |
| #7a sagas | `/system/sagas` | recent multi-step operations, which step failed, whether rollback succeeded |
| #7b resource ownership | `/system/orphans` | Docker/OS resources with no live owner; owner actors missing expected resources |
| #7c property tests | CI output | shrink counterexamples per actor; invariant violations |
| #7d circuit breakers | `/system/breakers` | state per breaker (closed/open/half-open), trip count, last trip timestamp, fail rate |
| #8 checkpoint recovery | `/system/recovery` | snapshot size + age per actor; last boot's recovery time; fallback usage |
| #9 saga journal | `/system/sagas` (extended) | in-flight sagas on boot, resumed vs rolled-back count, failed rollbacks |
| #10 quarantine | `/system/quarantine` | quarantined actors + reason; quarantined events + trigger; un-quarantine controls |
| #11 graceful degradation | `/system/health` | component tree: healthy / degraded / down + dependency graph |
| #12 safe mode | `/system/health` | boot-time banner during recovery; log of what reconcilers corrected |

**First page to land: `/system/events`.** It's the backbone. Everything else either reads from the same ETS ring buffer or composes its own view of the data stream. Build it early (week 2 with move #2) and the rest of the observability surfaces become cheap composites.

**Telemetry catalog:**

- `[:boom_looper, :events, :publish]` — every broadcast. Measurements: `%{size, count: 1}`. Meta: `%{topic, event}`.
- `[:boom_looper, :transitions, :applied]` — every state-machine transition. Measurements: `%{duration_us}`. Meta: `%{actor, from, to, event}`.
- `[:boom_looper, :reconcile, :run]` — every reconciler scan. Measurements: `%{drift_count, duration_ms}`. Meta: `%{reconciler}`.
- `[:boom_looper, :reconcile, :drift]` — one per drift event. Meta: `%{kind, before, after, corrected}`.
- `[:boom_looper, :deadlines, :expired]` — when the scanner forces a transition. Meta: `%{actor, state, age_ms}`.

These are the prod signals. LiveDashboard consumes them for free; a downstream OTLP/Prom pipeline can subscribe too.

## Execution plan

| Week | Move | Effort | Outcome |
|------|------|--------|---------|
| 1 | #1 pure transitions | 3–4 days | every state change is auditable & compiler-checked |
| 2 | #2 publisher modules + #7 telemetry/tap | 3 days | no raw broadcast calls; typed payloads; timeline view |
| 3 | #3 subscriber behaviours + #4 OwnedState | 4 days | missing-handler = compile warn; ETS + log auto-projected |
| 4 | #5 deadlines + #6 reconcilers | 3 days | no stuck states; cache drift detected & corrected |
| 5 | #7a sagas + #7b resource ownership | 4 days | no partial-success states; no orphan resources |
| 6 | #7c property tests + #7d circuit breakers | 3 days | transition invariants tested; retry-storms bounded |
| 7 | #8 checkpoints + #9 saga journal | 3 days | bounded recovery time; durable transactions |
| 8 | #10 quarantine + #11 degradation + #12 safe mode | 3 days | crash-loops bounded; partial outages visible; unclean boot detected |

Each move is independently valuable and shippable. The ordering is load-bearing: #1 is a prerequisite for #4 (need a single mutation site) and #7c (need pure functions to property-test), #2 is a prerequisite for #3 (behaviour references the structs), #7 piggybacks on the publisher wrapper from #2.

Weeks 5–6 are optional if weeks 1–4 close the bug classes we're hitting. Revisit after Week 4 retro.

## What we don't do

- **No event-sourcing rewrite.** The log stays an append-only backup, not source of truth. Log-as-truth is a 6-month migration with its own bugs — not justified yet.
- **No PubSub replacement.** Loose coupling is still correct for 1-to-N across ephemeral LVs. We're adding a contract, not a new transport.
- **No codebase-wide type annotations.** Typed event payloads + state-machine transitions cover the coordination layer. Other code stays as-is.
- **No GenServer rewrite.** The GenServer pattern stays; only the internals get strict.

## Success criteria

- No silent `handle_info(_msg, _)` catch-alls in any actor under `lib/boom_looper/`. Unknown messages raise in dev and log a telemetry event in prod.
- Every state-machine actor has a pure transition function, a deadline, and a reconciler.
- Zero raw `Phoenix.PubSub.broadcast` calls outside `lib/boom_looper/events/`. Enforced by CI.
- `EventTap.recent(topic, 30_000)` reproduces any reported race within 30s.
- `[:boom_looper, :events, :publish]` and `[:boom_looper, :reconcile, :drift]` telemetry feed a dashboard showing event rates and drift events.
- Existing broadcast coverage test (`test/boom_looper_web/broadcast_coverage_test.exs`) stays green as a safety net, but the primary contract is compile-time (behaviour + Dialyzer).
- Every multi-step operation goes through `Saga.run/1`; no direct sequence of mutations. Partial-success state unreachable.
- Every owner process implements `ResourceOwner` or has a documented reason not to. `/system/orphans` is empty in steady state.
- Property tests (via `StreamData`) cover every state-machine actor's transition function. CI green.
- Every call to an external dependency goes through a named circuit breaker. Tripping one doesn't cascade.
- `mix compile --warnings-as-errors` and Dialyzer in CI. No warnings merged.
- Boot time from a log of any size is O(snapshot), not O(history). Checkpoints keep recovery bounded.
- Every saga either completes or rolls back cleanly on boot — no in-flight sagas survive a restart without resolution.
- No actor restarts more than N times in T seconds without transitioning to `:quarantined` with an alert. Operators see crash loops before they burn hours.
- `/system/health` reflects reality: a Docker outage shows degraded components with a clear dependency chain, not a blank UI.
- Unclean shutdown triggers safe-mode boot with reconciler log visible. System refuses new work until recovery is confirmed.

## Complexity review: which moves are worth it as specified

Every abstraction is a liability. Before building any of these, check whether it's actually justified by the concrete cases we have — not by hypothetical future ones. Here's the honest grade per move:

### Ship as specified (7 moves)

- **#1 Pure transitions** — foundational, compile-checked exhaustiveness. Keep scoped to the 4–5 actors that actually have bugs. Resist applying to every GenServer.
- **#2 Publisher modules** — straight refactor, low risk, high return. The CI grep is the enforcement.
- **#5 Deadlines** — one GenServer, existing `entered_at`. Main risk is wrong thresholds causing false-positive timeouts, which is worse than a stuck state. Start conservative (generous timeouts) and tighten from real data.
- **#7 Event tap + telemetry** — dev/test only, pure observability, negligible risk.
- **#7c Property tests** — free once #1 lands. Tests don't create bugs, they surface them.
- **#10 Quarantine** — directly addresses a shipped bug (26 restarts/hour). Worst-case failure mode is over-protective, easy to un-quarantine.
- **#12 Safe mode** — ~50 lines, catches compounding corruption, no downside.

### Narrow the scope (4 moves)

- **#3 Subscriber behaviours → skip the macro dispatcher.** The `@behaviour` + `@callback` part is fine. The macro that auto-generates `handle_info(%Struct{} = e, socket)` routing to the right callback is where bugs hide. Let each LV write its own two-line dispatch. Less DRY, less magic, same compile-time safety.
- **#4 OwnedState → start as a 30-line helper, not a framework.** Make `ChatAgent.put_state/2` do the atomic ETS+log+broadcast write. If WorkspaceGroup needs the same pattern later, extract a shared helper. Don't design a generic abstraction for a population of 1.
- **#6 Reconcilers → only where source of truth is unambiguous.** Docker reconciler works because Docker is external truth. Agent reconciler (ETS vs Registry) is fine — Registry wins. **Workspace reconciler is risky** — if registry and supervisor tree disagree, which wins? A reconciler that "corrects" the wrong direction is a drift amplifier. Build the agent reconciler; defer the workspace one until we have a clear invariant.
- **#11 Graceful degradation → flat health map, no dependency graph.** Start with `%{docker: :healthy, claude: :degraded, mutagen: :down}`. UI reads it and renders banners. The component dependency tree is framework-thinking for a population of 3 components. Add it later if we ever have 20.
- **#7d Circuit breakers → consolidate existing backoff, don't build a new abstraction.** We have ad-hoc backoff in `Docker.docker/2` (3 retries) and ChatAgent crash-backoff (exponential). Extract those into a shared `Retry` helper. Skip full circuit-breaker state machine until a retry storm actually bites — the current ad-hoc limits already cap the damage.

### Drop until a concrete case forces them (4 moves)

- **#7a Sagas** — over-engineered for N=3 multi-step operations (start workspace, boot agent, destroy workspace). A saga framework has rollback-ordering bugs, idempotency requirements, and compensation semantics that take months to debug. Instead: write each multi-step op as an imperative function with explicit `try/rescue` cleanup. When we have 10+ similar ops, reconsider. Until then, sagas add a new bug class (failed rollbacks) to fix a bug class (partial success) that only rarely bites.
- **#7b Resource ownership** — generic framework for a few specific owner-resource pairs (agent → CLI process, workspace → containers, PortRegistry → port bindings). Each already has its own mechanism (`Port` linking, compose, explicit registry). Fix leaks specifically when found. Don't unify.
- **#8 Checkpoints** — premature. Current log compaction (shipped) handles the "log too big" case. We haven't hit "replay too slow" in practice. Build when we do. Wrong snapshot implementation = silent data loss, which is worse than the problem it solves.
- **#9 Saga journal** — depends on #7a. If sagas don't ship, this doesn't exist. Even with sagas, durable transactions are where distributed-systems researchers go to die. Skip unless a specific incident justifies it.

### Underlying principle

**Frameworks for N=3 cases are almost always wrong.** The plan reads impressively because it names a pattern for every bug class. But each named pattern is also a liability: a thing you have to maintain, debug, and explain to new contributors. The real test: would I write a one-off fix for the next case, or reach for the framework? If "one-off fix" is faster and clearer, the framework is overhead.

Apply the narrower versions first. If they leak, extract patterns. Don't design patterns in advance of three concrete cases that demand them.

### Revised scope

With drops and narrowings, the shipped plan is:

**Weeks 1–4 (baseline):** Moves 1, 2, 3 (narrowed), 4 (narrowed), 5, 6 (narrowed to Docker + agents), 7, 10, 12.

**Weeks 5+:** Move 7c (property tests, cheap). Moves 7d and 11 (narrowed). Defer 7a, 7b, 8, 9 until concrete cases force them.

That's 9 moves, ~4 weeks, closing every bug class we've actually shipped. The deferred four are real patterns that might become necessary — but not yet.

## Open questions

- **Scope of actors to convert to pure transitions.** Start with the four that caused real bugs (`ChatAgent`, `ServiceManager`, `WorkspaceGroup`, `Cluster`); defer `SyncMonitor`, `PortRegistry`, etc. unless they bite us.
- **Deadline defaults.** `:booting` at 5 min, `:starting` at 2 min, `:thinking` at 10 min — confirm against real-world p99 before shipping. Wrong bound causes false-positive transitions; right bound catches real stuckness.
- **Reconciler interval.** 30s for Observer works. For agent/workspace reconcilers, might need tighter (10s) if stale-state symptoms surface fast, or looser (60s) if the diff is expensive.
- **Prod telemetry sink.** LiveDashboard is fine in dev. Pick a long-term sink (OTLP? Prometheus?) before shipping move #7 to prod.
- **Saga compensation semantics.** If a rollback step itself fails, what happens? Options: (a) retry the rollback with backoff, (b) escalate to a manual-intervention alert with full saga state dumped for forensics, (c) mark the resource as "orphan — requires reconciler." Default to (b) — hiding a broken rollback is how data corruption ships.
- **Circuit breaker thresholds.** Open after N failures in T seconds, half-open after S seconds. Wrong values either flap or miss real outages. Start with N=5, T=30, S=60 and tune from real trip data on `/system/breakers`.
- **Resource ownership edge cases.** What happens when two owners legitimately share a resource (e.g. two agents using the same workspace container)? Reference counting or explicit lease? The simple answer is "one resource, one owner" — if we hit a case that violates it, that's a design smell worth revisiting first.
