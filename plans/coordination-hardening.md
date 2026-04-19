# Coordination Hardening

Goal: eliminate entire **classes** of bugs from the core compose + agent coordination layer, not the individual instances. After this plan lands, the communication and state layers both have compile-time contracts, observable timelines, and structural guarantees of eventual consistency.

## The bug classes we're eliminating

Each of these is a real bug shipped this sprint:

1. **State drift** — GenServer state, ETS, LV assigns, and the persistence log hold overlapping copies. They disagree under race, partial failure, or resume paths. _(Sleepy agent, zeroed Claude panel.)_
2. **Silent broadcast drops** — messages land in `handle_info(_msg, _)`. No compiler or runtime signal. _(Workspace LV ignoring `:chat_agent_resumed`.)_
3. **Stuck-forever states** — `:booting`, `:starting`, `:crashed` have no structural guarantee of eventual transition. _(Workspace pinned at Starting after compose failure.)_
4. **Reality-vs-cache divergence** — Docker truth is external; our mirror can drift silently. _(Observer cache going stale when the event stream stops.)_
5. **Broadcast slop** — raw `Phoenix.PubSub.broadcast/3` called from ~30 sites with tuple-typed payloads. No contract between producer and consumer. _(Any future event-shape change breaks subscribers invisibly.)_

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

### 7. Dev-mode event tap + telemetry on every publish

`BoomLooper.Events.Tap` — supervised GenServer subscribed to every topic, writes the last 1000 events to an ETS ring buffer with timestamps. `EventTap.recent("chat_agents", 30_seconds)` returns a timeline. Attached in `:dev` and `:test` only.

Publisher modules emit `:telemetry.execute([:boom_looper, :events, :publish], %{size: byte_size(bin)}, %{topic: t, event: mod})`. Free LiveDashboard, free metrics, assertable-in-tests (`assert_receive_telemetry/1`).

**Kills:** "we couldn't reproduce the race." Next sleepy-agent report, you read the tape.

## Execution plan

| Week | Move | Effort | Outcome |
|------|------|--------|---------|
| 1 | #1 pure transitions | 3–4 days | every state change is auditable & compiler-checked |
| 2 | #2 publisher modules + #7 telemetry/tap | 3 days | no raw broadcast calls; typed payloads; timeline view |
| 3 | #3 subscriber behaviours + #4 OwnedState | 4 days | missing-handler = compile warn; ETS + log auto-projected |
| 4 | #5 deadlines + #6 reconcilers | 3 days | no stuck states; cache drift detected & corrected |

Each move is independently valuable and shippable. The ordering is load-bearing: #1 is a prerequisite for #4 (need a single mutation site), #2 is a prerequisite for #3 (behaviour references the structs), #7 piggybacks on the publisher wrapper from #2.

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

## Open questions

- **Scope of actors to convert to pure transitions.** Start with the four that caused real bugs (`ChatAgent`, `ServiceManager`, `WorkspaceGroup`, `Cluster`); defer `SyncMonitor`, `PortRegistry`, etc. unless they bite us.
- **Deadline defaults.** `:booting` at 5 min, `:starting` at 2 min, `:thinking` at 10 min — confirm against real-world p99 before shipping. Wrong bound causes false-positive transitions; right bound catches real stuckness.
- **Reconciler interval.** 30s for Observer works. For agent/workspace reconcilers, might need tighter (10s) if stale-state symptoms surface fast, or looser (60s) if the diff is expensive.
- **Prod telemetry sink.** LiveDashboard is fine in dev. Pick a long-term sink (OTLP? Prometheus?) before shipping move #7 to prod.
