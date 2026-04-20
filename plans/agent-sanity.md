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

2. **If we drop state, the UI MUST say so.** Silent loss is the worst
   failure mode — the user can't tell the agent is broken vs. just being
   terse. Any gap between user expectations and reality surfaces via a
   visible marker:
     - Inline system message on the conversation (e.g. "⚠ Reconnected —
       last 3 turns of context were not recovered")
     - Sidebar status indicator (colored dot + hover explanation)
     - Never just a log line the user won't see.

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

### 2. Token/cost/model accounting across restart

**Suspected gap**: token counts, cost, model name accumulate in
`state.total_input_tokens`, `state.total_cost_usd`, `state.model`. These
are in `summary/1` so they should survive, but test coverage is thin.
Verify that a restart mid-conversation does not zero the Claude panel.

- [ ] Failing test: agent logs N turns, restart the GenServer via
  `resume: true`, assert tokens/cost/model are preserved byte-for-byte.
- [ ] Fix anything that drops them.
- [ ] Also verify: cost accumulates CORRECTLY after resume (not doubled,
  not reset, not NaN from a missing field).

### 3. In-flight message preservation when CLI dies mid-stream

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

### 4. Active tool state surviving restart

**Suspected gap**: `state.active_tool` is the name of the tool call
currently executing. If the CLI dies while `docker_compose up` is mid-exec,
the agent restart leaves `active_tool: "docker_compose"` stuck in ETS
forever, or the UI shows a perpetual "Running docker_compose…" spinner.

- [ ] Failing test: set active_tool, kill session, observe post-restart
  state. Assert `active_tool` is cleared on restart OR re-verified
  against a live tool process.
- [ ] Fix: clear `active_tool` in `init_resume` (already partially done
  per the code I saw) + in every restart path.

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
