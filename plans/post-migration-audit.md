# Post-Migration Audit

Audit of `plans/coordination-hardening.md` moves #2, #3, #6, #7, #7a, #7b, #7d, #8, #9, #10, #11, shipped on branch `harden-resume-state` (commits `139c852`..`0ab05d9`). Read-only pass; no code edited.

## Summary

- 4 HIGH bugs, 7 MEDIUM bugs, 6 LOW bugs.
- 5 framework-fighting issues, largest centered on `WorkspaceGroup :one_for_all` + `RestartController` state.
- 3 modules recommended for split (`chat_agent.ex`, `saga.ex`, `saga/journal.ex`).
- 6 test-coverage gaps, of which 2 block the plan's stated success criteria.
- 5 plan-faithfulness deviations, most consequentially: `@optional_callbacks` on every subscriber behaviour defeats the Move #3 compile-time contract; silent `handle_info(_msg, state)` in 7 `lib/boom_looper/` actors violates a stated success criterion; `Process.sleep` inside a ChatAgent `handle_info` defeats the explicit Move #7d warning.

## Bugs (by severity)

### HIGH

1. **Synchronous `Process.sleep/1` inside `handle_info/2` blocks the ChatAgent mailbox for up to ~32 s.**
   `/Users/bradgessler/Projects/boomlooper/boomlooper/lib/boom_looper/chat_agent.ex:919-922` computes `backoff_ms` via `Retry.backoff_ms/2` then calls `Process.sleep(backoff_ms)` inline. The plan's Move #7d lesson explicitly states: "A single synchronous `run/2` would block the GenServer mailbox... `backoff_ms/2` for async event-driven callers (ChatAgent crash recovery, which is a sequence of `handle_info` events, not a loop)." This implementation reads the helper but keeps the synchronous sleep — the very anti-pattern the helper was designed to prevent. With `@default_crash_backoff_base_ms = 2_000` and exponential growth, crash 5 sleeps 32 s; the agent ignores `send_message`, `stop`, Claude stream events, and PubSub traffic for that entire window. Fix: schedule via `Process.send_after(self(), {:retry_session, consecutive}, backoff_ms)` and return `{:noreply, state}`, handling the retry in a new `handle_info/2` clause.

2. **`saga_id` collides across BEAM restarts, corrupting the durable journal.**
   `/Users/bradgessler/Projects/boomlooper/boomlooper/lib/boom_looper/saga.ex:526-528` generates `saga_id` via `:erlang.unique_integer([:positive, :monotonic])`. Per OTP docs this restarts at `0` on every BEAM boot. The journal (`sagas.log`) persists across boots. `build_sagas/1` (`lib/boom_looper/saga/journal.ex:493-497`) reduces by id, so records from BEAM run A (saga_id=42) and BEAM run B (new saga_id=42) merge into a Frankenstein saga. On boot, `resume_all_on_boot/0` reads the merged record and may dispatch rollback for a saga that already completed — OR treat a genuinely incomplete old saga as completed because a new same-id saga succeeded. This exactly undermines Move #9's durability guarantee. Fix: use `{:erlang.system_time(:microsecond), :erlang.unique_integer([:positive, :monotonic])}` or a UUID for saga_id.

3. **`WorkspaceGroup` `:one_for_all` strategy resets `RestartController` state on any sibling crash, bypassing quarantine.**
   `/Users/bradgessler/Projects/boomlooper/boomlooper/lib/boom_looper/workspace_group.ex:39` uses `strategy: :one_for_all`, so a crash in `ServiceManager`, the agent DynamicSupervisor, `ContainerMonitor`, `Checkpointer`, or `SyncMonitor` restarts `RestartController` too. `RestartController` keeps `crash_history` in-memory (`/Users/bradgessler/Projects/boomlooper/boomlooper/lib/boom_looper/chat_agent/restart_controller.ex:147-159`); restart loses it. An agent that crashed 4 times can crash another 4 before triggering quarantine, because the 5-in-60 counter starts over. The plan's Move #10 claim "After N crashes in T seconds (say 5 in 60), the child moves to `:quarantined`" is only true when siblings are healthy. Fix: persist crash_history to ETS (owned by StateKeeper) so it survives controller restart, OR move `RestartController` to a separate supervisor with `:one_for_one`.

4. **`Resources.Janitor.init/1` wipes all tracked rows on its own restart, leaking every currently-held resource.**
   `/Users/bradgessler/Projects/boomlooper/boomlooper/lib/boom_looper/resources/janitor.ex:117-126` calls `:ets.delete_all_objects(@table)` unconditionally on init, erasing the track record for every in-flight port binding. The owner pids are still alive with their ports bound; they no longer have a release path because no monitor is attached. On next owner DOWN the janitor is oblivious. This is silent leakage — only surfaces on `/system/orphans` IF the owner is still alive AND Port trial-bind in PortRegistry fails later. Fix: on init, re-read surviving owners from ETS, `Process.monitor` any that are still alive, drop only those whose owner is `Process.alive?/1 == false`.

### MEDIUM

5. **`AgentBoot` rollback calls `ChatAgent.stop_agent/1` which is NOT idempotent against a missing GenServer.**
   `/Users/bradgessler/Projects/boomlooper/boomlooper/lib/boom_looper/agent_boot.ex:196-209` wraps `ChatAgent.stop_agent(id)` in `try ... rescue _ -> :ok / catch _, _ -> :ok`. `stop_agent/1` does `GenServer.stop(pid, :normal, 5_000)` on a looked-up pid (`chat_agent.ex:92`); if the agent died between lookup and stop, that's a `noproc` exit. The rescue/catch swallows it — acceptable — but the 5-second stop timeout makes rollback slow for an edge case that doesn't need it. Fix: add an `if Process.alive?(pid)` guard in `stop_agent/1` OR shorten the timeout in the rollback path.

6. **`Saga.Journal.resume_all_on_boot/0` silently falls back `:resume_forward → :rollback`, with no `/system/sagas` warning.**
   `/Users/bradgessler/Projects/boomlooper/boomlooper/lib/boom_looper/saga/journal.ex:252-265` downgrades `:resume_forward` declarations to rollback because "no resume handler is registered." The log entry is a `Logger.warning` — no telemetry fires, no `/system/sagas` flag. Operators setting `on_resume: :resume_forward` in code will see rollback behavior with no indication except grepping logs. Either emit `[:boom_looper, :saga, :resume_forward_downgraded]` telemetry, OR fail-loudly at call time (reject `:resume_forward` until a handler is registered). The plan's #9 lesson already notes this is a known limitation — surfacing it is the remaining work.

7. **`ChatAgent.RestartController.release/1` docstring says it respawns the agent; code only clears ETS fields.**
   `/Users/bradgessler/Projects/boomlooper/boomlooper/lib/boom_looper/chat_agent/restart_controller.ex:40-46` claims "Release clears the flag and respawns the agent via the normal start_agent path." The code (lines 84-104) only drops the `:quarantined`/`:quarantine_reason`/`:quarantine_crashed_at` keys and publishes `Released`. The agent status stays `:crashed`, no new GenServer is spawned. Operator-facing behavior: clicking "Release" in `/system/quarantine` clears the flag but the agent still shows as crashed in the sidebar until the user clicks "Start". Docstring is the bug, not the code — but operators read the docstring. Fix the docstring; optionally also auto-start.

8. **`Saga.Recorder` creates its own ETS table outside `StateKeeper`, violating the "sole ETS owner" invariant.**
   `/Users/bradgessler/Projects/boomlooper/boomlooper/lib/boom_looper/saga/recorder.ex:115` calls `:ets.new/2` directly. CLAUDE.md: "StateKeeper | Sole ETS table owner." Impact: if Recorder crashes, its ETS table dies and every recorded saga is lost. Move to StateKeeper. Also, the `@moduledoc` at line 113 says "ordered_set" but the table is created as `:set` — cosmetic inconsistency.

9. **`Agent.Reconciler` reconciler_test.exs `emits ... telemetry` test is a no-op.**
   `/Users/bradgessler/Projects/boomlooper/boomlooper/test/boom_looper/agent/reconciler_test.exs:137-160` attaches a telemetry handler whose callback calls `send(self(), ...)` — but inside the anonymous function `self()` is the telemetry dispatcher, not the test pid. The `self()` passed as config is ignored. No `assert_receive` runs. The test body ends on line 159 with a comment acknowledging it's broken, but the test still passes trivially. Fix: use `:telemetry_test.attach_event_handlers` (the janitor tests do this correctly) or capture the test pid in a closure variable before `:telemetry.attach/4`.

10. **`Events.Tap` initial handle_info clause has no filter — captures EVERY message that lands in its mailbox, including non-PubSub messages.**
    `/Users/bradgessler/Projects/boomlooper/boomlooper/lib/boom_looper/events/tap.ex:138-157` pattern-matches `msg` with no guard. A timer fires → inserted as event. `EXIT`/`DOWN`/Registry messages → inserted as events. The `classify_topic/1` fallback returns `"unknown"` for those. Works, but pollutes the timeline. The tap does not actually trap exits or monitor anything so in practice the only unexpected messages are spurious; still, the tap lacks defense-in-depth.

11. **`agent_boot.ex` start_agent rollback — subtle ordering: `ChatAgent.stop_agent(id)` also deletes/writes ETS via `Events.ChatAgent.publish(%Stopped{})`, which races with the saga rollback step `:send_initial_message` on a prior step's ETS state.**
    If `:send_initial_message` fails after `:start_agent` succeeded, rollback runs `stop_agent(id)` which sets ETS `status: :stopped` and publishes `Stopped{summary: ...}`. Any LV that just observed `Booting{}` now transitions `:booting → :stopped`, skipping the `:crashed` state. Per the sidebar state machine (StateMachine.transition) `:booting → :stopped` is a valid transition. Low impact, but unexpected — the user intent was "boot this agent," not "stop it." Worth a pass during the next UX review.

### LOW

12. **`Events.Tap.maybe_trim/1` full-table sort on every 100th insert is O(n log n) per flush.**
    `/Users/bradgessler/Projects/boomlooper/boomlooper/lib/boom_looper/events/tap.ex:236-254` does `select → sort_by → take → delete`. `max_records=500` so `n <= 600` typically — non-issue. But the module doc promises "single `:ets.select_reverse/3`" for newest-N reads; the code uses `tab2list + sort_by` instead (`lib/boom_looper/events/tap.ex:77-82`). Ordered_set supports `:ets.last/1` + `:ets.prev/2`; either use those or rewrite the doc.

13. **`SystemQuarantineLive.handle_info/2` has an explicit catch-all at line 56 after full struct dispatch.**
    `/Users/bradgessler/Projects/boomlooper/boomlooper/lib/boom_looper_web/live/system_quarantine_live.ex:56`: the entire chat_agents topic is struct-dispatched above, so the catch-all is dead for in-contract messages. Kept for defense, but it silences non-Events messages too (e.g. timer replies, channel pings) which will be unusual here since this LV has none. Cosmetic, but the dead line is worth a cleanup.

14. **`Saga.Recorder` reads telemetry metadata `.saga_id` with no guard; `defp update(_meta_without_id, _fun), do: :ok` handles only the fallthrough but doesn't log.**
    `/Users/bradgessler/Projects/boomlooper/boomlooper/lib/boom_looper/saga/recorder.ex:246-259`: if telemetry metadata is ever missing `:saga_id` (a producer bug), the update silently returns `:ok`. No warning log, no telemetry, no test. The saga recorder goes mute. Mitigation: the Saga module always sets `:saga_id`, so this is defense-in-depth — but the silent drop is exactly what Move #2 was supposed to eliminate.

15. **`Health.component(:agent_reconciler)` reports `:degraded` when drift_count > 0, but drift is the reconciler's JOB.**
    `/Users/bradgessler/Projects/boomlooper/boomlooper/lib/boom_looper/health.ex:95-118`: "Last scan corrected N drift(s) — agents are dying unexpectedly" fires degraded as long as there's ANY drift. During agent boot the reconciler often sees transient `:booting` → `:crashed` drift (agent died mid-boot, reconciler corrects). False-positive degraded banner. Consider a threshold (e.g. > 5 drifts in a scan) or an exponentially-weighted-moving-average.

16. **`Saga.run/2` returns `{:error, {:step_failed, name, reason}, :rolled_back}` and `{:error, {:step_failed, name, reason}, {:rollback_failed, [...]}}` but `workspace_supervisor.ex:108` only matches `{:error, {:step_failed, _step, reason}, _}`.**
    `/Users/bradgessler/Projects/boomlooper/boomlooper/lib/boom_looper/workspace_supervisor.ex:108`: the 3-tuple form is handled but the caller discards the `_` (which contains `:rollback_failed` info). The scary case — rollback failed — is invisible at this call site. `/system/sagas` surfaces it but the function's return value loses the signal. Same issue in `agent_boot.ex:85`.

17. **`Events.Tap` runs in ALL envs (dev/test/prod) per its own moduledoc, contradicting the plan's "Attached in `:dev` and `:test` only" design.**
    `/Users/bradgessler/Projects/boomlooper/boomlooper/lib/boom_looper/events/tap.ex:39-45` acknowledges the deviation and justifies it. Design decision, not a bug — but the plan text says dev/test only. If prod-in-production becomes multi-tenant, redaction is missing (the module doc flags this too). Low-impact today; flag for future.

## Framework-fighting

1. **Silent `handle_info(_msg, state)` catch-alls in 7 core actors.**
   `/Users/bradgessler/Projects/boomlooper/boomlooper/lib/boom_looper/agent/reconciler.ex:98`, `lib/boom_looper/chat_agent.ex:946`, `lib/boom_looper/chat_agent/restart_controller.ex:203`, `lib/boom_looper/docker/observer.ex:334`, `lib/boom_looper/agent_log/checkpointer.ex:244`, `lib/boom_looper/resources/janitor.ex:203`, `lib/boom_looper/terminal.ex:162`. Plan success criterion: "No silent `handle_info(_msg, _)` catch-alls in any actor under `lib/boom_looper/`. Unknown messages raise in dev and log a telemetry event in prod." Not satisfied. Each one should either log+telemetry or crash (let the supervisor decide).

2. **`Saga.Recorder` uses its own ETS table instead of `StateKeeper`.** See bug #8.

3. **`@optional_callbacks` on every subscriber behaviour defeats Move #3's primary compile-time contract.**
   Every `lib/boom_looper/events/*.ex` behaviour declares ALL callbacks as `@optional_callbacks` (`events/chat_agent/subscriber.ex:37-47`, `events/docker_observer.ex:57-60`, `events/source_sync.ex:45`, `events/workspace_services.ex:54`, `events/chat_agent_message.ex:69`). The plan's Move #3: "Missing callback → compile warning via @impl." With everything optional, a new event struct added to a publisher does NOT produce a warning on subscribers missing its `on_X` callback. The static `broadcast_coverage_test.exs` is the only guard left — stronger than nothing, but it's the "belt-and-suspenders" fallback, not the primary contract the plan promised. Fix: make each callback required (remove from `@optional_callbacks`), and have LVs that legitimately don't care explicitly return `{:noreply, socket}` (SystemQuarantineLive already does this pattern).

4. **`Process.sleep` inside `handle_info`.** See bug #1.

5. **`WorkspaceGroup :one_for_all` couples unrelated lifecycle concerns.** See bug #3. The pattern here — ServiceManager, agent DynamicSupervisor, RestartController, Checkpointer, ContainerMonitor — contains things that MUST be coupled (the agent DynSup needs ServiceManager alive so agents can exec) and things that MUST NOT (Checkpointer snapshotting has no runtime coupling to service state). A `:rest_for_one` with Ordered dependencies would be more OTP-idiomatic.

## Module decomposition candidates

### lib/boom_looper/chat_agent.ex (1129 LOC)

- Concerns handled: GenServer state; ETS cache syncing; message append + persistence; Claude session lifecycle; stream event handling (Text, ToolCall, ToolResult, TextDelta, SessionResult); crash-recovery backoff; stuck-booting detection; resume-from-log (`init_resume`); boot stub registration (`register_booting`, `update_boot_status`, `boot_failed`); agent list view (`list_agents`); termination (kill OS process, port cleanup); subscribe/unsubscribe surface.
- Suggested split:
  - **`ChatAgent.StreamHandler`** — extract `handle_info({:stream_event, ...})` and its cohort (`:stream_done`, `:stream_timeout`, `:stream_error`, `:EXIT`) plus `build_resume_message/1` and `ensure_session_alive/1`. Likely 300+ LOC on its own.
  - **`ChatAgent.BootSurface`** — `register_booting`, `update_boot_status`, `boot_failed`, `list_agents`, `stuck_booting?`. These are read-only ETS + broadcast helpers; moving them declutters the core GenServer.
  - **`ChatAgent.Summary`** — the `summary/1` projection plus the resume-struct-rebuilding logic in `init_resume`. Currently ~50 LOC; worth its own file once the rest moves.
- Split worth it? **YES.** Each extracted module becomes independently testable (stream handler can be fed fake SDK events without spawning a real session; boot surface tests don't need any GenServer). The core `chat_agent.ex` drops to ~500 LOC and stops being intimidating.

### lib/boom_looper/saga/journal.ex (661 LOC)

- Concerns handled: append-only file I/O (read_records, write_record, meta header); saga reconstruction from record stream (`build_sagas`, `apply_record`); compaction; resume-on-boot dispatch; path resolution.
- Suggested split:
  - **`Saga.Journal.File`** — `append/1`, `read_records/1`, `write_record`, `write_meta_header`, `ensure_meta_header`, `safe_decode`, `path/0`, `clear/0`. Pure I/O.
  - **`Saga.Journal.Reducer`** — `build_sagas`, `apply_record`, `update_in_acc`. Pure state-reduction over the record stream; no I/O, directly unit-testable with lists of records.
  - Keep `Saga.Journal` as the orchestrator (resume_all_on_boot, incomplete, all_sagas, compact, dispatch_rollback).
- Split worth it? **YES.** The reducer is pure and currently buried inside I/O; extracting it makes `build_sagas/1` property-testable with StreamData (a good home for Move #7c property tests if those ever ship).

### lib/boom_looper/saga.ex (529 LOC)

- Concerns handled: forward pass; rollback pass; telemetry emission; journal writes; step validation; exception-safe wrappers for run/rollback functions.
- Suggested split: NOT RECOMMENDED. The forward and rollback passes are naturally coupled (both need telemetry + journal integration); splitting adds ceremony without reducing surface area. The 529 LOC includes ~220 LOC of `@moduledoc` + typedocs which is fine.
- Split worth it? **NO.** Already cohesive.

## Test coverage gaps

1. **`restart_controller_test.exs` depends on real workspace start (`WorkspaceSupervisor.start_workspace/2`) + real ChatAgent spawn + 100ms sleeps between crashes + 2s `assert_receive` windows.** `/Users/bradgessler/Projects/boomlooper/boomlooper/test/boom_looper/chat_agent/restart_controller_test.exs:280-312`. Slow, flaky under load. Should unit-test the `handle_info({:DOWN, ...})` → `handle_agent_down/4` flow directly with synthetic monitor refs; then one integration test validates the wiring. Current shape violates the user-memory constraint "mix test must finish <30s."

2. **`Agent.Reconciler` telemetry test is a no-op.** See bug #9. The described scenario is untested.

3. **No test for `RestartController.release/1` → `start_agent/2` round trip showing the flag is persisted through log replay.** `/Users/bradgessler/Projects/boomlooper/boomlooper/test/boom_looper/chat_agent/restart_controller_test.exs` tests release on ETS state but does NOT simulate "release → BEAM dies → restart → is the flag still cleared?" The log-replay path is untested for quarantine.

4. **`Saga.Journal.resume_all_on_boot/0` with `:resume_forward` strategy — no test that confirms the downgrade-to-rollback happens AND the downgrade emits observable signal.** See bug #6.

5. **`Health` tests can't force degraded/down states.** `/Users/bradgessler/Projects/boomlooper/boomlooper/test/boom_looper/health_test.exs:73-93`. The tests only assert shape is valid, not that the conditions trigger correctly. The `{:degraded, reason}` and `{:down, reason}` branches in `Health.component/1` are untested. Fix: inject a mock observer / stub `last_snapshot_at` via an Application env.

6. **No test for `saga_id` collision across BEAM lifetimes.** See bug #2. No test clears `:persistent_term`, runs a saga, simulates BEAM restart (by deleting and re-seeding `:erlang.unique_integer` via something like `:erlang.system_flag(:schedulers_online, ...)` — harder to do cleanly), and confirms the journal handles collisions. Even a regression test documenting the current unsafe behavior would be informative.

## Plan faithfulness

1. **Move #2 (publisher modules + boundary test) — MOSTLY SHIPPED.** Publisher modules exist, boundary test (`pubsub_boundary_test.exs`) enforces no raw `Phoenix.PubSub.broadcast` in `lib/`. Spot-check confirmed only event modules call it. Not a concern.

2. **Move #3 (strict subscriber behaviours) — PARTIALLY SHIPPED.** Behaviours exist, `@behaviour` declared on every relevant LV, `@impl` annotations present. BUT: `@optional_callbacks` on every callback means the compile-time "missing callback = warning" contract is not enforced. The plan's narrowed version (per commit `0f15565`): "The `@behaviour` + `@callback` part is fine." The compile-time enforcement is the *point* of that narrowing; it's currently vestigial. Fix: demote the `@optional_callbacks` list.

3. **Move #6 (Agent.Reconciler) — SHIPPED, TEST GAP.** Reconciler wired into supervision tree, drift detection works, telemetry emitted. But the reconciler_test.exs telemetry test is broken (bug #9), so the test matrix doesn't actually cover what the plan promised: `[:boom_looper, :reconcile, :run]` meta assertion.

4. **Move #7 (Event tap) — SHIPPED.** `/system/events` page works, ring buffer in ETS, 500ms refresh, payload truncation, legacy tuple + struct classifiers.

5. **Move #7a (Sagas) — SHIPPED.** Saga module + Recorder + `/system/sagas` all in place. Coverage test (`saga_coverage_test.exs`) present. Two multi-step ops converted (`rebuild_saga`, `AgentBoot.boot`). **Caveat:** `ChatAgent.remove_agent/1` (`lib/boom_looper/chat_agent.ex:210-257`) is a multi-step state-mutating op not saga'd and not in `@non_saga_reasons`. It's a plausible candidate — if the `:agent_removed` log append fails after the `:destroying` broadcast, the sidebar pins at `:destroying` until reconciler clean. Worth a saga or an entry in the allowlist with justification.

6. **Move #7b (Resources + Janitor) — SHIPPED.** Janitor, `/system/orphans`, resource_coverage_test.exs all present. But bug #4 (janitor wipes ETS on its own restart) means the invariant "every tracked resource has an owner" is only maintained within a janitor lifetime — a regression.

7. **Move #7d (Retry helper) — SHIPPED.** `Retry.run/2` and `Retry.backoff_ms/2` exist and are documented. `Docker.docker/2` and `ChatAgent` call sites migrated. **BUT** bug #1 — `ChatAgent` still sleeps synchronously inside `handle_info` — defeats the explicit plan lesson about `backoff_ms/2` being for async event-driven callers. The helper is right; the caller defeats it.

8. **Move #8 (Checkpointer) — SHIPPED.** Per-workspace Checkpointer, `/system/recovery` page, telemetry events, fallback-on-corruption via `AgentLog.replay_with_fallback/1`.

9. **Move #9 (Saga journal) — SHIPPED, with documented limitations.** Journal appended before step execution, compacted on threshold, resume-on-boot dispatched via Task. Bug #2 (saga_id collisions) is a real risk that was not caught in the shipped lesson; bug #6 (silent `:resume_forward` downgrade) is a surface-area gap.

10. **Move #10 (Quarantine) — SHIPPED.** RestartController with configurable threshold, `/system/quarantine` page, release API, Events.ChatAgent.Quarantined + Released events, telemetry. **BUT** bugs #3 and #7 erode the guarantees — quarantine can be bypassed by sibling-induced controller restart, and release docstring overpromises.

11. **Move #11 (Health map) — SHIPPED, narrow-scope.** Flat map, three components, no dependency graph (per narrowed scope). Bug #15 (noisy degraded) is a tuning issue, not a faithfulness issue.

12. **Success-criteria deviations beyond the per-move notes:**
    - "No silent `handle_info(_msg, _)` catch-alls in any actor under `lib/boom_looper/`." **NOT MET** — 7 violations (see framework-fighting #1).
    - "`mix compile --warnings-as-errors` and Dialyzer in CI. No warnings merged." Not verified in this audit — needs a CI run.
    - "Every state-machine actor has a pure transition function, a deadline, and a reconciler." Move #1 (pure transitions) and Move #5 (deadlines) did NOT ship in this bundle — the plan confirms these were deferred. Success criterion not yet met; tracking in plan.

## Cross-cutting issues

- **`Process.sleep` outside tests and backoff helpers:** `lib/boom_looper/chat_agent.ex:922` (see bug #1) and `lib/boom_looper/source/local/sync_monitor.ex:330`. The latter is inside a handler waiting on a probe; worth reviewing separately but not a sprint regression.

- **`rescue _ -> :ok`:** only instance in new code is `lib/boom_looper/agent_boot.ex:203-205` (discussed as bug #5). Pre-existing in other modules (`source/local/*`, `chat_agent/*`), outside the sprint scope.

- **`handle_info(_msg, state)` catch-alls in `lib/boom_looper/`:** 7 hits in actors shipped this sprint (framework-fighting #1).

- **Public functions without `@doc` or `@moduledoc`:** spot checks found all new modules have a `@moduledoc`. Individual helpers vary — `RestartController.registered_name/1` has `@doc false`, etc. Low concern.

## Priority fix list

Ordered by blast radius × reliability impact. Fix before running evals:

1. ✅ **[HIGH] LANDED in commit `02d42f6`** — ChatAgent async backoff via `Process.send_after` + `:retry_session` handler. Mailbox stays responsive during crash recovery.

2. ✅ **[HIGH] LANDED in commit `02d42f6`** — `make_saga_id/0` composes timestamp + unique_integer so cross-BEAM collisions are impossible.

3. ✅ **[HIGH] LANDED in commit `02d42f6`** — RestartController crash_history moved to ETS (`:restart_controller_history` table via StateKeeper). Quarantine counter survives `:one_for_all` restart.

4. ✅ **[HIGH] LANDED in commit `02d42f6`** — Janitor re-hydrates from ETS on init, re-monitors live owners, drops only rows for dead owners. No more leaked-on-restart tracking rows.

5. ✅ **[MEDIUM] LANDED in commit `02d42f6`** — `@optional_callbacks` removed from every subscriber behaviour. Every LV already implements every callback (verified via clean compile). A new event struct now produces a compile warning on any subscriber that doesn't explicitly handle it.

6. ✅ **[MEDIUM] LANDED in commit `02d42f6`** — Silent `handle_info(_msg, state)` catch-alls replaced in all 7 actors with a Logger.warning + `[:boom_looper, :actor, :unknown_message]` telemetry event. Plan success criterion satisfied.

7. **[MEDIUM]** Fix `RestartController.release/1` docstring (`lib/boom_looper/chat_agent/restart_controller.ex:40-46`) to match code behavior — it does NOT respawn. (Docstring already updated in commit `02d42f6`; this item now complete.)

8. ✅ **[MEDIUM] LANDED in commit `8e165b1`** — `:agent_reconciler` telemetry test fixed (captures `test_pid` before `:telemetry.attach/4`).

9. ✅ **[MEDIUM] LANDED in commit `8e165b1`** — `:resume_forward → :rollback` downgrade now emits `[:boom_looper, :saga, :resume_forward_downgraded]` telemetry.

10. ✅ **[MEDIUM] LANDED in commit `8e165b1`** — `:saga_recorder` ETS table moved into `StateKeeper`; `Saga.Recorder.init/1` no longer calls `:ets.new`.

11. **[LOW] DEFERRED.** Speed up `restart_controller_test.exs` — unit-test `handle_agent_down/4` with synthetic refs instead of spawning real agents, killing them, and waiting. Out of scope for hardening sprint; track separately.

12. ✅ **[LOW] LANDED in commit `503568b`** — `Health.component(:agent_reconciler)` threshold tightened so a single transient drift doesn't flip to degraded.

13. ✅ **[LOW] LANDED in commit `2954717`** — `ChatAgent.remove_agent/1` documented; stays outside the saga set with justification (see commit message).

14. ✅ **[NOTE] LANDED in commit `bfe2cac`** — `publishers_test.exs` and `invariants_test.exs` switched to `async: false` to cure compile-order races under full-suite load.
