# Agent Sanity — survive restarts, crashes, and reconnects without amnesia

## Why

The coordination-hardening sprint made supervisors restart deterministically,
quarantine crash loops, track resources, and replay the agent log. None of
that caught the biggest UX bug in the product: **the agent forgets the
conversation on any CLI or server restart**. 455 messages in the sidebar,
`Turns: 9` on the Claude panel, and the agent replies "I don't have context
from a prior conversation."

That bug sat since commit `b1c6fdd` (2026-03-17) because the test suite
proves supervisor trees restart correctly but proves **nothing about
conversation integrity**. Users experience the failure the first time they
restart the server or the CLI crashes. A single unfixed root cause produced
every symptom: `ClaudeCode.start_link` was called without `resume:` on
every session replacement path.

The commit that fixes the root cause (`8a1ccc6`, continued in `ba99392`)
captures the Claude CLI `session_id` on every `%Event.SessionResult{}`, persists
it, and threads `resume:` through all four restart paths + `init_resume`. That
covers one surface. This plan widens the lens: every other place where the
agent touches durable state needs the same "does it actually survive a
restart?" check, driven by failing tests first.

**Scope**: agent process, Docker container lifecycle, MCP tooling, message
streaming, token/cost accounting, service/port state, Claude API failure
modes (rate limit, auth, 5xx). Everything a user reasonably expects to
persist across restart should be provably preserved.

**Non-goals**: multi-node affinity (one workspace = one node is already the
contract), offline Claude API caching, cross-project agent memory.

---

## Guiding principles (apply to every surface below)

1. **Recover as much as possible.** When a gap exists, best-effort fill it.
   Example: pre-fix agents have no captured `claude_session_id`; we can
   still call `ClaudeCode.History.list_sessions(project_path: wd)` and
   offer to resume the most-recent on-disk session. "Best effort + visible
   status" beats "silent reset to zero."

2. **If we drop state, the UI MUST tell the user: WHY, CONSEQUENCE,
   ACTION.** Silent loss is the worst failure mode — the user can't
   tell the agent is broken vs. just being terse. Every unrecoverable
   event surfaces THREE things:

     - **Why**: what actually failed ("CLI auth token expired",
       "rate-limit exhausted for 2h", "workspace volume unreachable").
     - **Consequence**: what won't work ("Claude won't respond to new
       messages", "your last 3 turns were not saved", "this agent is
       quarantined until 5 min of silence").
     - **Action**: what the user can do ("Re-run `mix boom.setup` and
       restart this agent", "wait 24m — next retry at 14:32", "fix
       the underlying volume then click Restart").

   Channels in priority order:
     - Inline system/error message in the conversation (always — this
       is the channel the user is already looking at).
     - Status badge on the agent sidebar row (for persistent states
       like `:rate_limited`, `:auth_expired`, `:quarantined`).
     - Agent context panel for the full why/consequence/action text.
     - `/system/*` pages for ops visibility + telemetry.
     - **Never just a log line the user won't see.**

3. **Backoff and rate limits are first-class behavior, not an
   exception path.** Every retry loop must be exponential + jittered +
   capped. Every 429 / 5xx from the Claude API must surface as a clear
   UI state ("rate-limited — retrying in 30s") not a crash or a stuck
   spinner. No infinite retries, no silent drops.

4. **Predictable means idempotent.** A restart mid-operation must either
   complete the operation or roll it back cleanly — never "partially
   applied and forgotten." `BoomLooper.Saga` already does this for
   multi-step ops; extend the discipline anywhere we're doing N
   sequential side effects without a rollback contract.

5. **Tests prove behavior the user cares about.** Every surface in this
   plan gets:
     - A failing test that demonstrates the current broken UX.
     - A passing test after the fix that locks in the correct behavior.
     - Where possible, a property-style test that fuzzes the timing
       (kill at random points during the operation).

---

## Surfaces to audit

Each surface gets a failing test first, then the fix, then a CI assertion
that locks the behavior in. Surfaces are roughly ordered by user-visible
blast radius.

### 1. Conversation context across session replacement — **PARTIALLY DONE**

- [x] Capture `claude_session_id` from `%Event.SessionResult{}` and persist
  in the summary/ETF log. (`chat_agent.ex`)
- [x] Thread `resume:` into session_opts on all four restart paths
  (`:restart_session` cast, `{:stream_error, "CLI session exited", …}`,
  `:retry_session`, `ensure_session_alive`).
- [x] `init_resume` passes saved `claude_session_id` through to
  `start_session` so server restart continues the same Claude thread.
- [x] Regression test: `test/boom_looper/chat_agent/session_resume_test.exs`
  (6 tests — capture, all four restart paths, init_resume).
- [ ] **Best-effort recovery for pre-fix agents with no saved
  `claude_session_id`.** Call `ClaudeCode.History.list_sessions(
  project_path: working_dir, limit: 1)` on resume; if a recent session
  file exists, offer to resume it. Mark the conversation with a
  sidebar/inline warning if the recovered session_id might not match
  the actual prior conversation (e.g. multiple agents share the dir).
- [ ] **UI gap-marker on forced amnesia.** When we cannot resume (no
  saved id AND no disk recovery), append a single inline
  `{role: :system, kind: :context_reset}` marker — rendered distinctly
  — so the user knows the CLI is starting fresh despite the visible
  history. Do NOT append this on clean resumes (the regression fixed
  in commit ba99392).
- [ ] **Telemetry**: emit `[:boom_looper, :agent, :context_gap]` on any
  forced amnesia event. Route to /system/events for ops visibility.

### 2. Token/cost/model accounting across restart — **DONE**

- [x] Regression test: `test/boom_looper/chat_agent/restart_state_test.exs`
  "surface #2" section simulates 3 turns via `%Event.SessionResult{}`,
  confirms all five accumulators (in/out/cache tokens, cost, model)
  survive a stop + `resume: true` cycle byte-for-byte.
- [x] The accumulators were already correctly plumbed — test locks in
  the behavior + guards against future regression. No code change
  needed beyond the test.

### 3. In-flight message preservation when CLI dies mid-stream — **DONE**

- [x] New state field `in_flight_partial` accumulates TextDelta text
  during a stream.
- [x] Event.Text / stream_done / new stream reset it.
- [x] `finalize_partial_on_stream_interrupt/3` finalizes non-empty
  accumulator as `%{role: :assistant, partial: true, content: text <>
  "⚠ Truncated — …"}` on stream_error / stream_timeout, persisted to
  the log + broadcast.
- [x] Telemetry: `[:boom_looper, :agent, :partial_finalized]` with
  byte count + reason.
- [x] Regression: `test/boom_looper/chat_agent/stream_integrity_test.exs`
  surface #3 section (4 tests).

### 3-legacy. Historical design notes (kept for reference):

**Suspected gap**: the agent is streaming an assistant message (TextDelta
events have fired; the full text hasn't persisted yet because the Text
event hasn't arrived). CLI dies. The agent restarts. What does the user
see? The partial message either:
- disappears silently (current behavior?),
- remains a ghost "thinking…" indicator forever,
- merges weirdly with the next turn.

Tool-call mid-flight is worse: the tool result might be half-streamed
when the CLI dies. Does the ChatAgent correctly surface the failure as
a tool error, or silently swallow it?

- [ ] Failing test: start a streaming turn, kill the session pid
  mid-stream, assert we either finalize the partial message with a
  clear "truncated — CLI crashed" marker OR drop it cleanly with a
  system message. Current behavior is probably neither.
- [ ] Fix: finalize-or-drop on stream_error; persist the decision.

### 4. Active tool state surviving restart — **DONE**

- [x] Every reset-to-new-status path now explicitly clears
  `active_tool`: `stream_timeout`, `stream_error` (both CLI-exit +
  generic), `:EXIT` → `:crashed`, `:EXIT` → `:backoff`,
  `dispatch_retry_session` (both success + failure), rate-limit
  `:rejected`, auth error, `init_resume`. Prevents UI spinners from
  pinning to "Running docker_compose…" forever after a mid-tool-call
  crash.
- [x] Regression test: `test/boom_looper/chat_agent/restart_state_test.exs`
  "surface #4" section — 7 tests, one per reset path.

### 5. MCP tool server lifecycle tied to agent lifetime

**Suspected gap**: MCP servers (stdio or SSE) are configured in
`ToolConfig.build_mcp_servers/2` and handed to the Claude CLI via
session_opts. When the CLI restarts, does the CLI spawn fresh MCP
connections? Do orphaned MCP processes from the dead CLI leak? Do MCP
tools carry ANY in-memory state that matters across restart?

- [ ] Audit: trace an MCP tool invocation end-to-end. What persists
  inside the MCP server? Anything user-meaningful?
- [ ] If the MCP server holds state (e.g. per-session auth), verify
  the new CLI re-establishes it before the user's next turn, with
  no visible failure.

### 6. Docker container persistence across BoomLooper restart

**Known good**: `ServiceManager.resume` reconnects to running
containers via `Compose.ps` after server restart. `Docker.Observer`
ETS cache is rebuilt from live docker state, not from BoomLooper's
memory of it.

**Suspected gap**: what if the BoomLooper server dies while a container
is mid-start (pulling image, running migrations, warming up)? On
restart, does the ServiceManager correctly pick up the in-progress
boot, or does it kick off a duplicate `compose up` that fights the
existing one?

- [ ] Failing test: start a workspace, crash the BoomLooper process
  mid-`docker compose up`, restart, assert the resumed ServiceManager
  either waits for the in-flight compose or no-ops because containers
  are already up. No duplicate `compose up`.
- [ ] Fix: idempotency check at resume boundary.

### 7. Port exposure registry across restart

**Suspected gap**: `PortRegistry` + `PortExposer` manage host-side
ports that forward into containers. On server restart, the exposers
are re-created from the persisted `ports.json`. `EADDRINUSE` warnings
already show up in the test logs ("Listen on 32866 failed:
:eaddrinuse") — the port may still be held by a stale process, or by
a docker-proxy from the previous run.

- [ ] Failing test: start a workspace, note the exposed port, restart
  BoomLooper, assert the port still forwards to the container OR is
  cleanly re-exposed with no EADDRINUSE.
- [ ] Audit: does the exposer verify the port is actually listening
  after "re-open", or does it just log the failure and move on?

### 8. Terminal buffer persistence across viewer reconnects

**Known**: terminal_echo_test.exs covers the "late joiner gets the
buffer" case. But does the buffer survive a BoomLooper server restart?
The terminal is a PTY subprocess — it dies with the server or with the
container. What should happen when the user refreshes the browser after
a restart? Blank screen? Replay? Message saying "terminal disconnected
— reconnect to new session"?

- [ ] Decide the contract. Right now it's probably "blank screen with
  no explanation."
- [ ] Failing test + fix.

### 9. Agent boot state across crash during boot

**Known**: `@stuck_booting_seconds = 300` — if an agent is in `:booting`
for more than 5 min, we mark it `:crashed` so the Start button appears
instead of a perpetual spinner.

**Suspected gap**: what happens in the first 5 min if the boot task
dies silently (TaskSupervisor kill, OS OOM, etc.)? The user stares at
a spinner for 5 minutes before any signal. Five minutes is long in
product-UX terms.

- [ ] Failing test: simulate a boot-task kill during boot, verify the
  user sees the failure within a reasonable window (<30s?).
- [ ] Audit: should boot register a `Process.monitor` on the task so
  we surface crashes immediately instead of on the 5-min timer?

### 10. Claude API rate limits, auth failures, and backoff — **PARTIALLY DONE**

- [x] New `%Event.RateLimitStatus{}` and `%Event.AuthStatus{}` events;
  `Backend.ClaudeCode` translates the SDK's `RateLimitEvent` +
  `AuthStatusMessage`.
- [x] New ChatAgent statuses: `:rate_limited`, `:auth_expired` +
  state fields (`rate_limit_status`, `rate_limit_resets_at_ms`,
  `rate_limit_type`, `auth_error`) exposed in `summary/1`.
- [x] `:rejected` → scheduled auto-retry at `resets_at_ms` (capped 1h
  for clock skew).
- [x] `:auth_expired` → no automated retry; user must re-authenticate.
- [x] `send_message` short-circuits both states so the CLI isn't
  hammered; user's message is logged with a visible explainer.
- [x] Telemetry emitted: `[:boom_looper, :agent, :rate_limit]`,
  `[:boom_looper, :agent, :auth_expired]`.
- [x] Regression test: `test/boom_looper/chat_agent/rate_limit_test.exs`
  (8 tests).
- [ ] **UI**: render the new statuses on the sidebar + agent context
  panel (badges, countdown for rate-limit, re-auth CTA for auth).
- [ ] Classify `{:stream_error, _, reason}` strings by kind (5xx,
  400, 413, network) and surface a corresponding status instead of
  lumping everything into a generic crash + backoff.
- [ ] Honor `Retry-After` header specifically if the SDK ever exposes
  it distinct from `resets_at_ms`.

#### Legacy rate-limits-via-CLI-crash (historical):


**Known gap**: the current `handle_info({:EXIT, _pid, reason}, :thinking)`
path catches streaming-task crashes and reschedules with exponential
backoff (`BoomLooper.Retry.backoff_ms/2`, capped at `@max_consecutive_crashes`).
But "session crashed" is the only failure mode it covers. The Claude API
can return 429 (rate-limited), 529 (overloaded), 401 (auth expired), 400
(bad request), 5xx (transient). Today those land as a `%Event.ToolResult{
is_error: true}` or a stream crash with no distinct UX.

**What ultra-reliable looks like here**:
- 429 / 529: surface `:rate_limited` status on the agent, show a
  countdown in the UI ("Rate-limited — retrying in 24s"), auto-retry
  with exponential backoff + jitter, respect `Retry-After` header if the
  SDK exposes it.
- 401: surface `:auth_expired` status, stop retrying, put a clear "Re-auth
  needed" CTA on the agent, link to the correct `/settings` page.
- 5xx: auto-retry up to N with backoff; after N, surface `:upstream_down`
  and stop. User can manually retry.
- 400 / 413 (context too big): surface immediately as a terminal error
  with a meaningful message. No silent retry — the request will fail
  the same way.

- [ ] Audit: instrument the ClaudeCode backend to classify stream errors
  by kind (429 / 5xx / 401 / 400 / network / other). Right now they're
  all stringified.
- [ ] Introduce `:rate_limited`, `:auth_expired`, `:upstream_down`
  statuses alongside the existing `:idle / :thinking / :backoff /
  :crashed`.
- [ ] Per-status UI treatment: badge, countdown, CTA.
- [ ] Tests: stub the backend to emit each error kind; assert the agent
  lands in the correct status and the correct UI markers.
- [ ] Tests: assert the retry scheduler respects jitter + cap and does
  not crash-loop the Claude API (important — uncapped retries against
  429 will get the whole account rate-limited and break everyone else).

### 11. Agent-to-agent message routing across restart

**Unclear**: if agent A sends a tool call that forwards a message to
agent B, and B is restarting, what happens? Does the message get
queued, dropped, dual-delivered? This is the same "in-flight message"
class as #3 but across agents.

- [ ] Audit the existing inter-agent tool paths (`send_message` /
  `append_external_message`). Look for assumptions about B being alive.
- [ ] Failing test + fix.

### 12. Resources.track/4 for the Claude CLI OS subprocess — **DONE**

- [x] `track_cli_os_pid/1` helper in ChatAgent: pulls OS pid via
  `OSProcess.pid_of/1`, releases any prior tracked pid, registers
  under `Resources.track(self(), :claude_cli, os_pid, release_fn)`.
- [x] Called on every session-start site: `init_fresh`, `init_resume`,
  `:restart_session` cast, `:stream_error` recovery,
  `dispatch_retry_session`, `ensure_session_alive`.
- [x] `terminate/2` stripped of manual `OSProcess.kill/1` — the
  Janitor runs the release fn on DOWN for any exit reason (normal,
  killed, shutdown-timeout, node crash).
- [x] `state.tracked_cli_os_pid` exposed in `summary/1` so
  `/system/orphans` + tests can observe it.
- [x] Regression test: `test/boom_looper/chat_agent/cli_tracking_test.exs`
  (5 tests covering the tracking discipline under the fake backend
  + a terminate/2-source assertion that catches re-introduction of
  the manual kill).
- [x] Tell-the-user path: `:boom_looper, :resources, :released`
  telemetry surfaces on `/system/orphans` + `/system/events`. Ops
  concern, no user-chat-channel message needed.

### 13. Session-id drift reconciler

**Gap**: `state.claude_session_id` is captured from the last
`%Event.SessionResult{}` and mirrored to the ETF log. It's possible
for the SDK Session GenServer to be holding a DIFFERENT session_id
(it captures from every assistant/result message, we only capture
from result messages). Drift = we resume the wrong thread on the
next restart. No alarm fires today.

- [ ] Add a per-agent `:sync_claude_session_id` tick every 30s (same
  cadence as Agent.Reconciler). Compare `state.claude_session_id` to
  `backend.session_id(state.session)`. On mismatch, update state
  + emit `[:boom_looper, :agent, :session_drift]` telemetry.
- [ ] Failing test: mock the backend to report a different session_id
  than state holds; advance the tick; assert state is corrected.
- [ ] Tell-the-user path: silent correction is fine for drift (user
  doesn't care about ids); `/system/events` carries the telemetry
  for ops.

### 14. Saga-wrapped turn execution

**Gap**: a turn is six+ sequential side effects:
  1. `ensure_session_alive` (may spawn new session),
  2. append user message to state + ETS + log,
  3. broadcast user message,
  4. start streaming Task (spawns a linked process),
  5. each `%Event.*{}` event: append message, persist, broadcast,
  6. `:stream_done`: bump turn counter, persist, broadcast :idle.

Any failure between (2) and (6) leaves a half-committed turn. The
current code tries to bolt on compensation in each `handle_info`,
but misses edge cases (e.g. ETS write succeeds, log append fails —
restart sees state that never happened).

- [ ] Model the turn as a `BoomLooper.Saga` with explicit
  compensating actions: e.g. if "start streaming Task" fails,
  rewind the appended user message and broadcast a compensating
  `:user_message_rolled_back` event.
- [ ] This is the biggest restructuring in the plan. Do it after
  #1, #2, #3 are landed so we have a stable base.
- [ ] Tell-the-user path: a rolled-back turn surfaces as a distinct
  inline `{role: :system, kind: :turn_rolled_back}` marker with a
  clear explanation. Never silent.

### 15. Concurrent `send_message` races — **DONE**

- [x] `state.pending_sends :: [String.t()]` queue.
- [x] `handle_cast({:send_message, text}, %{status: :thinking}/:backoff)`
  enqueues + appends an inline "Queued — agent is still working"
  marker, records the user message normally (so it's visible + persisted).
- [x] `drain_pending_sends/1` pops the head and calls
  `send_message_normal` inline; wired into `:stream_done`,
  `:stream_error`, `:stream_timeout`, `:rate_limit_retry` so turns
  drain in strict FIFO.
- [x] Regression: `test/boom_looper/chat_agent/concurrent_send_test.exs`
  (3 tests).

### 15-legacy. Design notes:

**Gap**: two humans (or a human + a tool-triggered auto-send) cast
`:send_message` nearly simultaneously to the same agent. The GenServer
processes them serially, but each cast spawns a linked Task that
calls `backend.stream(session, text)` — two parallel queries against
one Claude session. The SDK's Session has a `query_queue`, but we've
never tested the edge case. Likely failure mode: second message
interleaves TextDelta events with the first, or the CLI rejects the
second query with an error stream.

- [ ] Explicit per-agent send queue: only one streaming Task at a time;
  subsequent sends either queue (default) or reject with a "please
  wait — still thinking" system message.
- [ ] Failing test: two concurrent `:send_message` casts; assert
  ordering of emitted messages is deterministic.

### 16. Stale stream events after session replacement — **DONE**

- [x] Every `{:stream_event, id, event}` shape changed to
  `{:stream_event, id, ref, event}`. Same for `:stream_done` +
  `:stream_error`.
- [x] Ref-matched handlers land on state; mismatched events drop with
  `[:boom_looper, :agent, :stale_stream_event]` telemetry.
- [x] Regression: `test/boom_looper/chat_agent/stream_integrity_test.exs`
  surface #16 section (3 tests — mismatch drops, stream_done-mismatch
  keeps :thinking, match path mutates as control).

### 16-legacy. Historical notes:

**Gap**: the agent tracks `stream_ref` to discard stale
`:stream_timeout` timers from a previous stream. The same guard is
NOT applied to `{:stream_event, id, event}` messages. If the CLI
crashes and we spawn a new session before the old Task drains, the
old Task's remaining events land on the new state — wrong assistant
text appended, wrong tokens counted, wrong tool name recorded.

- [ ] Include the `stream_ref` in every `:stream_event` tuple:
  `{:stream_event, id, stream_ref, event}`. Handler drops events with
  a ref that doesn't match state.stream_ref.
- [ ] Failing test: start stream, replace session, send late stream
  events with the old ref; assert no state mutation.

### 17. ETF log torn writes / disk failures — **DONE (core)**

- [x] `Persistence.safe_append/4` catches raises + throws from
  `AgentLog.append/2`. On error: emits `[:boom_looper, :persistence,
  :error]` telemetry with path + reason + event kind, logs a clear
  warning telling the user their change won't survive a restart,
  returns `:ok`. ChatAgent keeps serving from in-memory state.
- [x] Torn-write recovery on replay was already handled by
  `AgentLog.read_entries` pattern-matching on
  `when byte_size(rest) >= size` — half-records fall through to the
  base case and are skipped silently.
- [x] Regression: `test/boom_looper/chat_agent/persistence_resilience_test.exs`
  (3 tests — persist_message / persist_agent / persist_message_update
  each with an unwritable path don't raise + telemetry fires).
- [ ] Follow-up TODO: surface the degradation in the UI (inline system
  message on first failure per agent, not just logs). Deferred to
  UI work — for now observable via `/system/events` + logs.

**Gap**: `Persistence.persist_*` calls `AgentLog.append` which raises
on disk full / permission denied. Raises in the ChatAgent handle_info
path kill the agent. A single disk-full event = all agents in that
workspace crash-loop. Separately, a crash mid-write can leave a
half-written length-prefixed record — replay either crashes parsing
or silently skips everything after the torn record.

- [ ] AgentLog.replay: detect + truncate to last valid record. Emit
  `[:boom_looper, :agent_log, :truncated]` telemetry with bytes
  discarded.
- [ ] Persistence.persist_* wraps `AgentLog.append` in a try/rescue.
  On disk error: transition the agent to a new `:persistence_degraded`
  status (not crashed), keep serving in-memory, surface clear inline
  message: "Can't write to disk — nothing you send right now will
  survive a restart. Fix the disk then Restart this agent."
- [ ] Failing test: persist_message with a non-writable path; assert
  agent survives + surfaces the degraded status.

### 18. Context window utilization visibility + compaction trigger

**Gap**: Claude has a finite context window (200K tokens on Sonnet,
1M on Opus 4.7). When full, the CLI silently starts dropping earliest
turns — the agent loses context without any signal to the user or
to us. Today we surface `cache_read_tokens` + `input_tokens` but no
"how much of the window are we using" percentage.

- [ ] Read `usage.input_tokens` + the model's window size (from the
  `model` string or a lookup table) on every `%Event.SessionResult{}`.
  Compute utilization; store on state.
- [ ] Surface on sidebar + context panel as a color-coded bar:
  green <70%, yellow 70-85%, red >85%.
- [ ] At 85%, automatically invoke context compaction (the CLI
  supports `/compact`; we'd call it via `ClaudeCode.Session` or
  via a tool). Surface "Compacted conversation to save context —
  older turns are summarized" inline.
- [ ] Failing test: simulate a SessionResult with utilization 0.9,
  assert compaction triggered + user sees the explanation.

### 19. System prompt drift on resume — **DONE**

- [x] `start_session/3` now returns the prompt's SHA-256 hash.
  `init_fresh` captures it; `summary/1` persists it so `init_resume`
  can compare.
- [x] On mismatch, init_resume appends an inline `⚠ System prompt
  changed since this agent's last boot…` message + emits
  `[:boom_looper, :agent, :prompt_drift]` telemetry with old/new
  hashes.
- [x] No-op for agents resumed without a saved hash (pre-fix
  rows) — no marker, just populate the new hash for next time.
- [x] Regression: `test/boom_looper/chat_agent/prompt_drift_test.exs`
  (5 tests).

### 19-legacy. Design notes:

**Gap**: `build_system_prompt` is rebuilt from scratch on every
`start_session`, pulling the latest CLAUDE.md + tool set. When we
`resume: sid`, the CLI has the OLD prompt baked into the conversation
+ we append the NEW prompt. Agent sees a mixed world: "Your instructions
are X" in old turns and "Your instructions are actually Y" appended.
After a major refactor (tool renamed, rule added), this can produce
confused behavior that looks like "the agent forgot everything" but
is really "the agent is honoring two conflicting system prompts."

- [ ] Hash the full system prompt. Persist hash alongside
  `claude_session_id` in summary/1.
- [ ] On resume, compare the new hash to the persisted one. If they
  differ, log it + surface an inline `{role: :system, kind:
  :prompt_changed}` marker: "The agent's instructions changed since
  the last session — behavior may differ. The older turns in this
  conversation were generated under the prior prompt."
- [ ] Failing test: stop an agent, edit the prompt, resume; assert
  the marker appears.

### 20. Idle-agent CLI reap — **DONE**

- [x] Periodic `:idle_check` tick (`Process.send_after`) scheduled
  from `init_fresh` / `init_resume` at interval
  `:agent_idle_check_interval_ms` (default 10 min).
- [x] Reap condition: `status == :idle` AND `is_pid(session)` AND
  `is_binary(claude_session_id)` AND idle for
  `:agent_idle_reap_hours * 3600` seconds (default 4h).
- [x] On reap: graceful `backend.stop/1` (3s cap), release tracked
  OS pid via `Resources.release/2`, null out `state.session` +
  `state.tracked_cli_os_pid`. Agent state (messages, tokens,
  session_id) is preserved; ONLY the CLI subprocess goes away.
- [x] Next `:send_message` goes through `ensure_session_alive`,
  which already spawns a fresh CLI with `resume: claude_session_id`
  → conversation continues seamlessly from user POV.
- [x] Telemetry: `[:boom_looper, :agent, :idle_reaped]` with idle
  duration.
- [x] Regression: `test/boom_looper/chat_agent/idle_reap_test.exs`
  (4 tests).

### 20-legacy. Design notes:

**Gap**: a long-idle agent holds a CLI subprocess forever. `claude` is
~200MB RSS + whatever the prompt cache retains. With 20 agents across
several workspaces, that's 4GB permanently held for sessions the user
may never return to.

- [ ] After N hours of idle (`state.last_activity_at` > threshold and
  status == :idle), stop the CLI subprocess via `backend.stop(session)`
  but keep state. Mark `state.session = nil`.
- [ ] Next `:send_message` goes through `ensure_session_alive` which
  already spawns a new CLI with `resume: claude_session_id` — context
  preserved, RAM reclaimed. User sees "Reconnected (resumed
  conversation …)" exactly the same as a CLI crash recovery.
- [ ] Telemetry: `[:boom_looper, :agent, :idle_reaped]`. Config:
  `Application.get_env(:boom_looper, :agent_idle_reap_hours, 4)`.
- [ ] Failing test: set last_activity to 5h ago, tick the reaper,
  assert session was stopped + context preserved.

---

## Test-suite speed (pre-requisite, not a surface)

The full `mix test` currently takes **73s serial / hangs in parallel**
due to an Elixir 1.19 parallel-compiler struct-resolution race for
nested modules (`defmodule Changed, do: defstruct([])` inside a parent
`Events.*` module). Target per user preference is **<30s**.

- [ ] Diagnose: reproduce the parallel-compile error outside the test
  suite. Confirm whether it's an Elixir 1.19.5 regression, a BoomLooper
  pattern issue, or both.
- [ ] Fix: either move struct defs out of their parent module into
  top-level files, or add explicit `Code.ensure_compiled/1` preambles
  on the publisher-testing modules.
- [ ] Prove: `mix test` passes with `--max-cases 20` in <30s and zero
  compile errors.

Locking in the speed contract belongs in CI:

- [ ] Add a CI guard that fails the build if `mix test` wall time
  exceeds 45s (30s target + headroom).

---

## Pre-existing failures to triage (baseline, not scope of this plan)

Full serial `mix test` shows 14 failures. 13 are pre-existing
(confirmed via `git stash` + rerun). Short list so they're tracked:

| # | Test                                                                                       | Suspected cause                              |
|---|--------------------------------------------------------------------------------------------|----------------------------------------------|
| 1 | `mcp_tool_names/0 returns sorted list of tool names`                                       | tool list drift since test was written       |
| 2 | `ConnectLive mount returns under 500ms`                                                    | dev-box speed variance                        |
| 3 | `every service_statuses assignment guarded against empty replacement`                      | invariant-test pattern mismatch               |
| 4 | `StateKeeper tables are referenced in application code`                                    | invariant-test reference drift                |
| 5 | `remove project deletes .boomlooper directory`                                             | cleanup timing race                           |
| 6 | `messages are capped at 1000`                                                              | "auto-continue" side-effect appends "Continue." — pre-existing, outside scope |
| 8 | `PortRegistry set_exposure/4 false stops the running exposer`                              | port-exposer race                             |
| 9–12 | `WorkspaceLive` various                                                                | likely same workspace-supervisor test fixture|
| 13 | `LaunchController redirects to workspace view`                                            | fixture/state                                 |
| 14 | `AgentBoot registers boot status updates before starting session`                         | boot-sequence test                            |

None of these are in scope for this plan. They're tracked here so we
see whether any of our agent-sanity changes move them.

---

## How we'll execute

One surface at a time, top-down. Each surface:

1. Write the failing test that demonstrates the bug. Do not fix yet.
2. Implement the minimal fix. Nothing else.
3. Confirm test passes + run the full targeted suite (fast subset).
4. Commit with the surface number and a one-line description.
5. Move to the next surface.

Pause points:

- After surface #3 (in-flight messages): sanity-check the three
  conversation-integrity surfaces together to make sure they compose.
- After surface #6 (Docker persistence): run a full integration scenario
  — start workspace, run a turn, `mix boom.server` kill -9, restart,
  verify conversation + containers + ports all came back clean.

Exit criteria for the plan:

- Every surface has a regression test that explicitly fails without
  the fix and passes with it.
- `mix test` runs in <30s with zero compile errors under parallel
  execution.
- A fresh BoomLooper restart against a 500-msg agent resumes to an
  unbroken conversation (user can say "keep going" and the agent
  remembers prior context).
- No silent catchalls on the agent process's mailbox: every unknown
  message surfaces via the existing `:boom_looper, :actor, :unknown_message`
  telemetry (already enforced in audit-2).
- Every 429 / 5xx / auth failure from the Claude API is visible in
  the UI with an actionable message. No indefinite spinners. No
  uncapped retries.
- Any forced amnesia event (context we couldn't recover) appears as
  an inline marker in the conversation AND a telemetry event at
  `/system/events` — never silent.

## Test coverage discipline

Beyond the per-surface regression tests, land these once:

- [ ] **Property test: kill at random points during a turn.** Start a
  turn, pick a random millisecond offset ≤ total turn duration, kill
  the session pid at that offset. Assert the post-kill state is
  coherent — no stuck `:thinking`, no orphan `active_tool`, no ghost
  partial messages, resume works cleanly.
- [ ] **Integration test: full restart cycle.** Boot workspace, run
  3 turns across 2 services, `GenServer.stop(BoomLooper.Application, …)`,
  restart, verify: services still running, agent resumes with
  `resume: sid`, token/cost accounting preserved, no duplicate
  containers.
- [ ] **Rate-limit chaos test.** Point the fake backend at a sequence
  `[429, 429, 429, 200]`. Assert the agent surfaces `:rate_limited`
  for three retries, backs off with exponential+jitter between them,
  then succeeds and clears the status.
- [ ] **CI speed guard.** Fail the build if `mix test` wall time
  exceeds 45s (30s target + headroom). Enforces the user's stated
  contract.

Anti-goals (explicitly rejected):

- Do NOT build a "conversation export" feature. The CLI owns history;
  we just need to not lose our pointer to it.
- Do NOT fall back to token-counting message summaries on resume.
  `resume:` is the only sanctioned path — anything else is amnesia
  with extra steps.
- Do NOT swallow rate-limit / 5xx errors with silent retry. Uncapped
  retries against 429 rate-limit the whole account; silent 5xx retries
  hide outages. Every transient failure must surface to the user with
  a bounded retry policy.
- Do NOT build a new settings page for "context recovery preferences."
  The correct behavior is automatic + visible, not user-configured.
