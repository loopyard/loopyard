# Post-Migration Audit (Second Pass)

Audit of `harden-resume-state` after commits `02d42f6`, `8e165b1`, `503568b`, `bfe2cac`, `2954717` landed the 1st-audit fixes. Goal: find what the first audit missed AND what the hardening batch itself introduced. Read-only pass; no code edited.

## Summary

- **2 HIGH, 5 MEDIUM, 5 LOW** new findings.
- One HIGH is a **regression introduced by the Move #6 silent-catch-all fix** in ChatAgent: every successful stream now triggers `[:boom_looper, :actor, :unknown_message]` telemetry + a Logger.warning because normal-reason `{:EXIT, task_pid, :normal}` messages fall through to the new noisy catch-all. Evals will drown in log output.
- The other HIGH is a **session-leak race in the new `:retry_session` async backoff**: `ensure_session_alive` inside `send_message` can spawn a replacement session during the backoff window, then `:retry_session` fires later and spawns a SECOND one.
- 3 silent `handle_info(_msg, state)` catch-alls in `lib/boom_looper/` actors (`container_monitor.ex`, `port_exposer.ex`, `source/local/sync_monitor.ex`) are **still present** — the plan's "no silent catch-alls" success criterion is **not yet fully met**.
- 1 MEDIUM: `Resources.Janitor.rehydrate_from_ets` drops release_fns for dead-owner rows — a real port/resource leak on a janitor-restart-then-owner-dies sequence.
- Typespec drift: `Saga.Journal.@type record` and `trace(integer())` still declare `saga_id :: integer()` but Saga now emits strings. Dialyzer will flag every caller.
- `log_buffer.ex` creates its own ETS table (violates "StateKeeper is sole owner") — missed by first audit.
- **Critical coverage gaps**: no test for the HIGH #3 fix (crash_history persistence across controller restart), no test for the HIGH #4 fix (janitor rehydrate of surviving owners + dropping dead-owner rows), no test for the new `:retry_session` async handler.
- `mix compile --warnings-as-errors --force` is clean (0 warnings).

## Bugs (by severity)

> **Status summary (as of commit `e421c36` + test coverage in `53f7907`):** all HIGH and MEDIUM items are LANDED. LOW items are either LANDED or documented as accepted. See annotations below.

### HIGH

1. **✅ LANDED in commit `35f07cc`.** **Normal-reason `{:EXIT, _, :normal}` messages from streaming tasks now spam the new unknown-message catch-all.**
   `/Users/bradgessler/Projects/loopyard/loopyard/lib/boom_looper/chat_agent.ex:908` guards on `%{status: :thinking} = state` AND `reason != :normal`. When a streaming `Task.start_link` fn returns normally, the task exits with `:normal`; trap_exit (enabled at line 385) converts that to `{:EXIT, task_pid, :normal}`. This falls through the status-and-reason guard, through every other clause, and lands at the new catch-all at line 984, which emits `Logger.warning("[ChatAgent] #{id} unhandled message: {:EXIT, ...}")` + `[:boom_looper, :actor, :unknown_message]` telemetry. **Every single successful stream** produces a spurious warning and telemetry event in dev, test, and prod. Before Move #6's catch-all fix the silent `{:noreply, state}` correctly absorbed these; now they're noise. In evals with many stream turns, this will flood the logs with false-alarms and mask real unhandled-message bugs. Fix: add `def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}` above the catch-all. (Or, more surgically, broaden the trap-exit handler to also accept the normal-exit case as `:noreply`.)

2. **✅ LANDED in commit `35f07cc`** (test coverage in `53f7907`). **`ensure_session_alive` racing `:retry_session` leaks Claude CLI sessions during crash backoff.**
   `/Users/bradgessler/Projects/loopyard/loopyard/lib/boom_looper/chat_agent.ex:908-938` schedules `{:retry_session, _}` via `send_after` and returns `:noreply` immediately (correct — fixes the synchronous sleep). BUT state.status stays `:thinking` during the backoff window, so a user's `send_message` cast arriving mid-backoff calls `ensure_session_alive/1` (`chat_agent.ex:1087`). That helper notices the session is dead (the original CLI died), calls `backend.start_session/1`, and **mutates state.session to a fresh session**. Now a user message streams on session A. When the previously-scheduled `:retry_session` fires (`chat_agent.ex:945`), it ALSO calls `backend.start_session/1` — replacing session A with session B, **orphaning** session A's OS process (no one holds its port). Two real consequences: (a) one leaked CLI process per send-during-backoff; (b) the user's in-flight stream on session A disappears mid-turn because state.session now points to session B. The in-memory crash counter is also double-incremented under the same condition (see related LOW #2 below). Fix: gate `:retry_session` on "session is still the dead one we were trying to restart" — stash `state.session` at EXIT time in state, compare in `:retry_session` and no-op if it's already been replaced.

### MEDIUM

3. **✅ LANDED in commit `35f07cc`** (test coverage in `53f7907`). **`Resources.Janitor.rehydrate_from_ets` drops dead-owner rows WITHOUT running their release_fns — real port/OS-resource leak.**
   `/Users/bradgessler/Projects/loopyard/loopyard/lib/boom_looper/resources/janitor.ex:136-154`. When an owner process dies during the window between the old janitor crashing and the new janitor starting, the new janitor's rehydrate path hits the `else` branch: `:ets.delete(@table, key)` + `orphan` telemetry, but the stored `release_fn` is **discarded without being called**. For `:port_binding` kind, the release_fn unbinds the OS port; dropping it leaks the port and the next `PortRegistry` attempt to use that {ws, service, port} tuple conflicts. The fix is small: in the dead-owner branch, call `run_release(release_fn, kind, id, :owner_dead_on_janitor_restart)` BEFORE `:ets.delete`. (The `run_release/4` helper already handles nil/bad functions safely.)

4. **✅ LANDED in commit `35f07cc`.** **`Saga.Journal.@type record` and `@spec trace(integer())` still declare `saga_id :: integer()` but `Saga.make_saga_id/0` now returns a `String.t()`.**
   `/Users/bradgessler/Projects/loopyard/loopyard/lib/boom_looper/saga/journal.ex:123-131, 198`. HIGH #2 of the first audit changed `make_saga_id/0` to `"#{system_time}-#{unique_integer}"` (a string). But Journal's typespec wasn't updated: every record variant declares `integer()` for the id slot, and `trace(integer())` is the declared arity. Dialyzer would flag every caller of `Journal.trace/1` and every producer of journal records. Not a runtime bug today (maps and `==` handle string keys fine), but it silences Dialyzer if/when it's wired in — and Dialyzer is explicitly in the plan's success criteria. Fix: `@type saga_id :: String.t()` and update every `record` variant + `trace/1` spec to use it.

5. **✅ LANDED in commit `e421c36`.** **Crash-history read-modify-write in RestartController is not atomic against concurrent `release/1`.**
   `/Users/bradgessler/Projects/loopyard/loopyard/lib/boom_looper/chat_agent/restart_controller.ex:289-298`. `handle_agent_down` does `read_history → filter → [now | filtered] → write_history`. Meanwhile `release/1` (line 94-117) runs **in the caller's process**, calling `purge_history_for/2` which is `:ets.delete(@history_table, key)`. If the operator clicks Release while a DOWN is in mid-read-modify-write, the sequence can be: (1) controller reads stamps, (2) operator deletes, (3) controller inserts `[now | stamps]`. Release silently fails — the crash counter is back. Same race for crash-on-release. Not data corruption, but the fix to audit HIGH #3 gains a race by moving state to ETS. Fix: serialize crash-history writes through the controller GenServer (add `{:purge_history, workspace_id, agent_id}` handle_call) OR use `:ets.update_element` / `:ets.safe_fixtable`.

6. **✅ LANDED in commit `35f07cc`.** **`log_buffer.ex` creates its own ETS table outside StateKeeper — missed by first audit.**
   `/Users/bradgessler/Projects/loopyard/loopyard/lib/boom_looper/log_buffer.ex:43`: `:ets.new(@table, [:named_table, :public, :set])`. Violates `StateKeeper` invariant ("No other code path calls `:ets.new`"). If LogBuffer crashes, every buffered log entry is lost AND the Logger handler continues to receive messages — `log/2` at line 74 guards with `:ets.whereis(@table) != :undefined` so no crash, but every log line between crash and restart is silently dropped. Same class as the first audit's Saga.Recorder finding (MEDIUM #8, fixed in commit 8e165b1). Fix: move to StateKeeper `@tables`.

7. **✅ LANDED in commit `e421c36`** (`:backoff` status + sidebar flash fix in `2ad6816`). **State stays `:thinking` during crash-backoff window — UI lies for up to the backoff duration.**
   `/Users/bradgessler/Projects/loopyard/loopyard/lib/boom_looper/chat_agent.ex:908-938` leaves `state.status = :thinking` when scheduling `:retry_session`. The sidebar + chat header show "thinking" for up to 32s while the agent is actually dead in the water. If the retry fails, the user eventually sees :idle and an error message, but for tens of seconds the UI claims forward progress that isn't happening. Lower priority than HIGH #2 because the observable damage is UX rather than resource, but still misleading. Fix: set `status: :backoff` (new state machine state) or at least `:idle` with an in-progress flag, and broadcast the change.

### LOW

8. **✅ LANDED in commit `35f07cc`.** **Three silent `handle_info(_msg, state)` catch-alls remain in `lib/boom_looper/` actors — plan success criterion still not fully met.**
   `/Users/bradgessler/Projects/loopyard/loopyard/lib/boom_looper/container_monitor.ex:28`, `lib/boom_looper/port_exposer.ex:155`, `lib/boom_looper/source/local/sync_monitor.ex:231`. The first-audit MEDIUM #6 fix patched 7 actors but missed these three. Container_monitor only receives `:poll` so silent-drop is probably safe, but port_exposer traps the acceptor-task EXIT already so random messages SHOULD be surfaced. SyncMonitor also handles DOWN/task messages explicitly; an uncategorized probe return would go silent. Finish what the fix started.

9. **✅ LANDED in commit `35f07cc`** (status → `:backoff` during window prevents the second EXIT; plus dead_session guard in `:retry_session`). **`consecutive_crashes` counter gets a DOUBLE increment when `:EXIT` arrives during the `:retry_session` backoff window.**
   `/Users/bradgessler/Projects/loopyard/loopyard/lib/boom_looper/chat_agent.ex:911`. While waiting for the scheduled retry, if a second `:EXIT :thinking` arrives (e.g. user sent a message that spawned a new task that also crashed — see HIGH #2 for why that's possible), the EXIT handler matches again and `Map.get(state, :consecutive_crashes, 0) + 1` increments to N+1. Two `:retry_session` messages are now queued. Both fire; both call `backend.start_session/1`. Also, because the counter increments twice, quarantine can be triggered one crash sooner than intended. Related to HIGH #2 and should be fixed in the same pass.

10. **NOT FIXED (accepted).** Test shape decision — flagged in original prompt as "note but don't fix." **Tests drive `Agent.Reconciler` via `:sys.replace_state` — fragile to any future state-shape change.**
    `/Users/bradgessler/Projects/loopyard/loopyard/test/boom_looper/health_test.exs:88-148`. The prompt flagged this as "note but don't fix," but worth recording explicitly: adding a key to Reconciler's state requires updating every test that does `fn state -> %{state | last_run: ...}`. Consider a public `set_last_run/1` test helper (or Mox the last_run reader). Pre-existing note, not a new finding, but it's relevant to the threshold tests landed in commit 503568b.

11. **✅ LANDED in commit `e421c36`** (sort on `{started_at, saga_id}` in both Recorder and Journal). **`Saga.Recorder.maybe_trim` uses `Enum.sort_by(fn {id, _} -> id end)` which depends on lexicographic comparison of the new string saga_ids.**
    `/Users/bradgessler/Projects/loopyard/loopyard/lib/boom_looper/saga/recorder.ex:291`. With current `"#{microseconds}-#{seq}"` format, microseconds is always 16 digits (true until year 2286), so lexicographic sort = chronological sort. Fine today but brittle: if the format ever changes (e.g. longer microsecond precision, or seq growing past width), trim starts deleting the wrong records. Consider sorting on a tuple `{started_at, saga_id}` stored in the record (the record already has `:started_at`). Same concern applies to `Journal.all_sagas()` `Enum.sort_by(& &1.saga_id, :desc)` (`journal.ex:222`).

12. **DEFERRED (operator workaround only).** Dev upgrades: delete `~/.boomlooper/*/sagas.log` — only affects dev boxes that ran code pre-commit `02d42f6`. No shipped mitigation needed; documenting in case we see it. **Pre-existing integer saga_ids in a dev `sagas.log` would interleave weirdly with new string saga_ids.**
    `/Users/bradgessler/Projects/loopyard/loopyard/lib/boom_looper/saga/journal.ex:222, 622`. `Enum.sort_by(& &1.saga_id, :desc)` on a mixed-type list puts all integers before all strings (per Elixir term ordering: `number < atom < ... < bitstring`). Historical records from before commit 02d42f6 would sort together as a block, breaking chronological ordering across the boundary. Workaround: `File.rm!(Path.join(home, "sagas.log"))` on upgrade (operator action, not code). LOW because after one compaction cycle old-format records ought to be dropped. But document or add a migration that drops the file if it contains any integer-keyed saga_started record. SUSPICIOUS — verify: does `build_sagas/1` properly handle integer keys at all today, or does `update_in_acc` blow up? It uses `Map.fetch(acc, id)` which handles mixed keys fine — so it works, just sorts oddly.

## Framework-fighting

1. **Monitors map lives in controller GenServer state, not in the ETS table that survived the first-audit HIGH #3 fix.**
   `/Users/bradgessler/Projects/loopyard/loopyard/lib/boom_looper/chat_agent/restart_controller.ex:166-176`. The comment acknowledges "monitors are dead anyway" on controller restart, and relies on "the next start_agent call" to re-attach. In a one_for_all restart, the agent DynamicSupervisor is also restarted (same supervisor), which means every agent is gone too — no DOWN can fire because the controller wasn't alive to receive one, and the agent is already dead. On restart, the controller has empty `monitors` and empty `agent_opts`, so the history in ETS is correctly preserved but has no way to respawn anything. That's actually fine — the user has to explicitly re-start agents after a group rebuild. Worth documenting as "group rebuild requires manual agent restart; quarantine counter survives but monitors don't." Currently just one terse comment.

2. **ChatAgent traps exits but only has ONE `:EXIT` handler clause** (`%{status: :thinking}` + `reason != :normal`). See HIGH #1 above. Either trap exits in every state (and add explicit clauses for normal and non-thinking cases) or don't trap them — right now the module is in-between.

## Test coverage gaps

1. **✅ LANDED in commit `53f7907`.** **No test exercises `RestartController` crash_history persisting through a simulated controller restart.** The HIGH #3 fix moved the counter to ETS so siblings' one_for_all restart can't reset it — but `test/boom_looper/chat_agent/restart_controller_test.exs` never crashes the controller and checks that the counter survives. A direct test:
   ```
   # Write crash-history to ETS
   # Crash the controller GenServer
   # Wait for restart
   # Trigger one more DOWN → assert quarantine triggers at the right count
   ```
   Critical for the fix. **HIGH-priority test gap.**

2. **✅ LANDED in commit `53f7907`.** **No test exercises `Resources.Janitor` rehydrating from ETS on restart.** `test/boom_looper/resources/janitor_test.exs` never kills the Janitor and checks that (a) live owners get re-monitored, (b) dead-owner rows are dropped with telemetry, (c) — and NOT checked at all today — release_fns run for dead-owner rows during rehydrate (MEDIUM #3 above). **HIGH-priority test gap.**

3. **✅ LANDED in commit `53f7907`.** **No test for the new `:retry_session` async handler in ChatAgent.** `test/boom_looper/chat_agent/crash_backoff_test.exs` tests the :EXIT handler's state mutations but stops before `:retry_session` fires (and zeros out `crash_backoff_base_ms` to sidestep it). The retry handler's both branches (success + :error on re-start) are untested. Critical because HIGH #2 above is precisely about the gap between EXIT and retry. **HIGH-priority test gap.**

4. **✅ LANDED in commit `e421c36`** (call-site telemetry tests added for both saga callers). **No test for `WorkspaceSupervisor.rebuild_saga` rollback-failed path** (`lib/boom_looper/workspace_supervisor.ex:110-121`) nor **`AgentBoot.boot` rollback-failed path** (`lib/boom_looper/agent_boot.ex:85-105`). Commit 2954717 added `Saga.maybe_log_rollback_failed/3` call-site plumbing + `[:boom_looper, :saga, :call_site_rollback_failed]` telemetry, but the only test that covers the telemetry is `test/boom_looper/saga_test.exs:454-490` — which constructs its own saga, not the two call sites. An integration test that forces a boot rollback to fail and asserts the telemetry fires at the `AgentBoot` call site would close the loop.

5. **✅ LANDED in commit `503568b`.** **No test that `ChatAgent.stop_agent/1`'s new `Process.alive?` guard short-circuits.** Commit 503568b added the guard for speed during rollback; `test/boom_looper/chat_agent_test.exs` has 40 new lines but I don't see an explicit "dead pid → sub-second return" test. Verify by searching for `Process.alive?` in the test file.

6. **DEFERRED.** Meta-test to catch future `@optional_callbacks` regression. Low-priority; covered by the `broadcast_coverage_test.exs` belt-and-suspenders. Worth adding eventually; not blocking. **No test that the Move #3 compile contract actually fires a warning on missing callback.** `@optional_callbacks` was removed (MEDIUM #5 fix) but there's no meta-test (à la `test/boom_looper_web/broadcast_coverage_test.exs`) that constructs a module with `@behaviour ChatAgent.Subscriber` missing an `on_*` callback and asserts the compile produces a warning. Without such a test, a future contributor re-adding `@optional_callbacks` can silently regress the contract. Worth a `Code.compile_string/2` + captured-warnings test.

## Plan-criteria verification

- **"No silent `handle_info(_msg, _)` catch-alls in any actor under `lib/boom_looper/`."** NOT MET. Three remaining: `container_monitor.ex:28`, `port_exposer.ex:155`, `source/local/sync_monitor.ex:231`. See LOW #8.

- **"`mix compile --warnings-as-errors` and Dialyzer in CI. No warnings merged."** Compile-warnings-as-errors ran clean (`mix compile --warnings-as-errors --force` with exit 0, zero warnings). Dialyzer not run in this audit; **would flag** MEDIUM #4 (saga_id typespec drift) on every `Journal.trace/1` caller and every `Saga`→`Journal` record producer. Suspicious; running `mix dialyzer` is outside read-only scope but noted.

- **"Every state-machine actor has a pure transition function, a deadline, and a reconciler."** Move #1 (pure transitions) and Move #5 (deadlines) still deferred per the plan. Not a regression.

- **"@optional_callbacks removed from every subscriber behaviour."** MET. Zero `@optional_callbacks` in `lib/boom_looper/events/`.

- **"saga_id unique across BEAM restarts."** MET. `make_saga_id/0` in `saga.ex:539-543` composes `system_time + unique_integer` as a string.

- **"RestartController crash_history survives controller restart."** MET at the ETS level (new `:restart_controller_history` table in StateKeeper). Not covered by tests (coverage gap #1).

- **"Resources.Janitor re-hydrates from ETS on init."** MET for live owners; the dead-owner branch leaks release_fns (MEDIUM #3). Not covered by tests (coverage gap #2).

- **"Saga rollback_failed surfaces at call sites."** MET. `Saga.maybe_log_rollback_failed/3` in `saga.ex:545-587`; called from both `workspace_supervisor.ex:114` and `agent_boot.ex:97`. Test covers the helper but not the two call sites (coverage gap #4).

## Cross-cutting issues

- **Silent `rescue _ -> :ok`:** only new instance is `lib/boom_looper/agent_boot.ex:223-229` (rollback step — documented as intentional best-effort, plus `stop_agent` now has alive-guard so the rescue rarely fires). Pre-existing instances in `source/local/*` and `chat_agent/*` unchanged. Not a regression.

- **`Process.sleep` in `lib/`:** only new usages are inside `Retry.run/2` (sanctioned), `eval_runner.ex` (eval harness, not hot path), and `sync_monitor.ex:330` (pre-existing probe loop inside a handle_info — same as first audit; not a regression).

- **ETS tables outside `StateKeeper`:** ONE new instance missed in first audit: `log_buffer.ex:43` (MEDIUM #6). First audit caught `saga_recorder` but missed this one.

- **Public functions without `@doc`:** spot-check on the new surface (RestartController's ETS-helpers, Saga's `maybe_log_rollback_failed`, Journal's `resume_all_on_boot`) shows `@doc` is present on all public functions. Private helpers without `@doc` are expected.

- **Module LOC growth:** `chat_agent.ex` 1129 → 1182 (+53), `restart_controller.ex` 387 → 415 (+28), `saga.ex` 529 → 588 (+59), `saga/journal.ex` 661 → 670 (+9), `resources/janitor.ex` ~340 → 399 (+59). None crossed architectural thresholds; the first audit's decomposition recommendations (ChatAgent → StreamHandler, BootSurface) remain valid but not more urgent.

## Priority fix list (before evals)

Ordered by user-visible reliability impact × likelihood to fire during an eval:

1. **[HIGH #1]** Add `def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}` in `chat_agent.ex` before line 984 — every successful stream currently spams unknown-message telemetry. **Evals will look "broken" in telemetry even when they succeed.**

2. **[HIGH #2]** Fix the `:retry_session` / `ensure_session_alive` session-leak race in `chat_agent.ex`. Either (a) store the "session we're retrying from" in state and skip the retry if state.session was replaced, or (b) flip state.status to `:backoff` during the window and teach `ensure_session_alive` to no-op when status is `:backoff`.

3. **[MEDIUM #3]** Run `release_fn` for dead-owner rows in `Janitor.rehydrate_from_ets` before deleting the ETS row. One-line change; prevents port leaks on janitor-then-owner crash sequence.

4. **[HIGH coverage gaps #1 + #2 + #3]** Add unit tests for the RestartController ETS-persistence fix, the Janitor rehydrate path, and the ChatAgent `:retry_session` handler. The entire reliability story of this sprint rests on three fixes that are not verified by tests.

5. **[MEDIUM #4]** Update `Saga.Journal.@type record` and `trace/1` spec to use `String.t()` for saga_id. Before Dialyzer runs and floods the board with warnings.

6. **[MEDIUM #6]** Move `log_buffer` ETS table into StateKeeper — matches the saga_recorder fix pattern.

7. **[LOW #8]** Replace the 3 remaining silent `handle_info(_msg, state)` catch-alls in `lib/boom_looper/` actors with log+telemetry or remove the trap-based arrival path so the message can't land. Completes the plan success criterion.

8. **[LOW #7]** Add a `:backoff` state to ChatAgent so the UI doesn't lie for up to 32s — nice-to-have for UX but not required before evals.

9. **[LOW #11]** Sort Saga.Recorder + Journal records on `{started_at, saga_id}` tuple rather than relying on string-sort being chronological. Brittle-but-works today.

10. **[LOW #5]** Serialize `RestartController` history ETS writes through the GenServer OR move `release/1`'s `purge_history_for` into a GenServer handle_cast to close the release/DOWN race.

Items 1–4 are the critical ones before running evals. Items 5–10 are pre-eval nice-to-haves.
