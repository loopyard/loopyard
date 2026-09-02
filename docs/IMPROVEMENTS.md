# Improvements backlog

A prioritized list of known, scoped improvements for Loopyard. Ordered within each section by blast-radius-per-effort. When you pick one up, move it to "In progress" at the top of the file (or delete when done and link the commit).

## Simplicity (less to read, less to misunderstand)

1. **Split workspace_live.ex (the last over-cap module).** The Jul 2026 audit
   split cards/chat/operator_live/stream_handler/acp-connection back under the
   800 default and brought chat_agent.ex under its 1700 allowance; only
   `workspace_live.ex` (~1840, allowance 1900) remains. The mapped seams: the
   `on_*` PubSub wrapper cluster → `WorkspaceLive.EventRouter`; the
   `handle_async/3` cluster → `WorkspaceLive.AsyncResults`; the
   service/port/sync handle_events → `WorkspaceLive.ServiceEvents`.

2. **Continue splitting workspace_live handler clusters (if they grow).** Git diff and file browser are out (`DiffLoader`, `FileBrowser`). Sync and cluster-control clusters were reviewed and judged too thin to earn modules — section comments are enough. Revisit if either grows meaningfully.

## Robustness (handles edge cases gracefully)

0. **Attachment retention / orphan sweep.** Uploads (`.loopyard/uploads`) are
   never deleted, and a LiveView that dies between copying files and
   consuming its entries leaves copies no message references. A safe sweep
   must treat "referenced by any persisted message" as the keep-set — that's
   a scan of the workspace's ETF log, not the ETS window — so it's deliberate
   work, not a cron with an age. Until then the dir grows with use; a fork
   copies it (it's in the volume), a fresh clone doesn't.

0. **Operator attachments assume one identity.** `/operator/attachments/:name`
   reads from `Workstation.current()`; a second identity's operator would 404
   on its own thumbnails. Put the identity in the path when multi-identity
   lands (`/operator/:identity/attachments/:name`).

0000. **SystemSagasLive empty-state test is order-dependent (seen on CI, 2026-08-16).**
      `test/loopyard_web/live/system_sagas_live_test.exs:39` asserts
      "No sagas recorded yet" but another test's saga journal entry leaked
      into the page under one seed (run 31947506699; green on rerun). Same
      family as the known shared-cwd/global-state pollution — the fix is
      isolating the saga journal per test (or clearing it in setup), not
      loosening the assertion.

0000. **claude-code-acp large-session + subprocess-death limits (upstream, worked around).**
      Confirmed against the ACP docs + upstream issues: `session/load` does a
      FULL-JSONL replay of the whole conversation, so a large session is slow to
      load and eventually hits token bounds ([discussion #871](https://github.com/orgs/agentclientprotocol/discussions/871));
      and when the underlying `claude` CLI subprocess dies, the ACP session is
      left permanently broken with no recovery — subsequent `session/prompt`
      fails with "ProcessTransport is not ready for writing"
      ([claude-agent-acp #338](https://github.com/agentclientprotocol/claude-agent-acp/issues/338)).
      Loopyard mitigates: the durable message inbox lives in ETS (not the
      harness), the reaper is age-guarded so it never kills an in-flight load,
      and a failed `session/load` falls back to a fresh `session/new`. Still
      worth doing: after N resume failures, permanently drop the poisoned
      session_id + surface "started a fresh conversation (previous one was too
      large to restore)" instead of retrying the monster each restart. The
      lighter `resumeSession` (restores SDK state WITHOUT replaying history) may
      be the better resume primitive than `session/load` for large sessions —
      investigate whether claude-code-acp exposes it over ACP.

000. **Upstream: claude-code-acp "ProcessTransport is not ready for writing" race.**
     (0.16.2) Prompting immediately after `session/load` of a large session dies
     with that error — the SDK's resumed CLI subprocess isn't writable yet when
     the prompt arrives. Loopyard mitigates with a 4s delayed drain after
     restart (`:drain_resumed_pending` in chat_agent.ex). File upstream; drop
     the delay when fixed. Also worth upstreaming: a failed `session/load`
     appears to leave the adapter unable to serve a subsequent `session/new`
     ("Query closed before response received" on both).

00. **"Unread response" / read-tracking for the overview's needs-you signal.** The
    workspace overview answers "is it waiting for me?" via pending question /
    approval / secret — but "the agent replied and you haven't read it" has NO
    backing state (multiplayer, no per-user read cursor anywhere). Needs a
    per-user last-seen cursor per agent (localStorage or server-side identity),
    then a `needs_you: :reply` tier. Scoped out of the overview redesign
    (July 2026) deliberately.

0. **Report (and ideally fix) the upstream `claude_code` interrupt-timeout bug.** `deps/claude_code/lib/claude_code/adapter/port.ex:102` — `def interrupt(adapter), do: GenServer.call(adapter, :interrupt)` uses the default 5s `GenServer.call` timeout, while every other control call in that file passes `:infinity`/`@default_control_timeout` (60s). When the CLI subprocess is wedged (stdin pipe full), the adapter's interrupt write blocks, the call times out at 5s, and `ClaudeCode.Session.Server` crashes. (Confirmed 0.36.5, the latest.) Loopyard now mitigates this in `ChatAgent.handle_cast(:interrupt)`: it runs the warm interrupt under `@interrupt_deadline_ms` (1.5s) and, if it doesn't ack, hard-restarts (kill + resume) to preempt the 5s self-crash — fast when healthy, reliable when wedged, no work lost. The clean upstream fix is to pass a timeout to that `interrupt/1` call (or make it a cast); file it / PR it and drop our deadline workaround once it lands.

1. **Declare `Boundary` boundaries for `Loopyard` / `LoopyardWeb` / `Loopyard.Events`.** The `:boundary` dep is installed but no `use Boundary` declarations exist yet, so it currently does nothing. Wiring it up is a real architectural pass:
   - Top-level `Loopyard` boundary (create `lib/loopyard.ex`) with `deps: []` and explicit exports for the modules `LoopyardWeb` is allowed to call.
   - `LoopyardWeb` boundary with `deps: [Loopyard]` — catches "web depends on domain, never reverse" at compile time.
   - Sub-boundary on `Loopyard.Events` that's the *only* module allowed to depend on `Phoenix.PubSub` — replaces `test/loopyard/pubsub_boundary_test.exs` with a compile-time check.
   - Sub-boundary on `Loopyard.Tools.Container` if the tool isolation rule is worth enforcing structurally.

   First compile will surface every cross-namespace edge in the codebase — expect a triage pass. Delete `test/loopyard/pubsub_boundary_test.exs` only once the Events boundary is enforcing.

3. **Migrate ChatAgent transition sites to `StateMachine.transition/2`.** The state graph and validator exist (`Loopyard.ChatAgent.StateMachine`). `remove_agent` already routes through it (closes the "remove → restart → remove again" race). The remaining ~20 direct `%{state | status: ...}` mutations in `chat_agent.ex` don't validate yet. **Highest-priority sites** — the ones most likely to race or drift from the graph:

   - `handle_cast(:restart_session, state)` — session restart path. Transitions through multiple states as the CLI reboots.
   - `handle_info({:stream_error, id, reason}, state)` — error recovery, often interleaved with user actions.
   - `handle_info({:EXIT, _pid, reason}, %{status: :thinking} = state)` — the async crash path.
   - `boot_failed/2` — boot failure transition.

   Opportunistic rule: when touching any of those sites, route the `%{state | status: X}` through `StateMachine.transition(state.status, X)` and log `EventLog.warning` on `{:error, {:invalid_transition, from, to}}`. If the warning fires in practice, the graph needs an entry OR the call site has a real bug. Pattern is `chat_agent.ex:remove_agent/1` as the reference.

4. **Consolidate `docker ps` port parsing.** Three modules each carry their own regex for parsing `"127.0.0.1:33958->3000/tcp"` style port strings: `Docker.Observer.parse_host_ports/1`, `Workspace.ServiceStatus.parse_ports/1`, and `Compose.parse_compose_ports/1`. They drifted — the first two hardcoded `0.0.0.0:` until the security change bound ports to 127.0.0.1, at which point both silently returned empty maps (sidebar port link disappeared; fixed commits `63f6434` + follow-up). Pull one `Loopyard.Docker.PortParser.parse/1` that owns the regex and the test matrix, and have all three call it. Small, pure module — adding it is lower risk than waiting for the next regex to rot.

5. **Soft volume quota.** Sidebar size badges exist (sourced from `Docker.Observer.fetch_volume_sizes` via `docker system df -v`). No warning threshold yet. First step: when `Docker.Observer` fetches sizes, sum per workspace; if total exceeds `Application.get_env(:loopyard, :workspace_soft_quota_bytes, 5_000_000_000)`, emit one `EventLog.warning` per poll (debounce so it doesn't spam) and render the sidebar badge in red. No hard stop — legitimate large workspaces shouldn't break. Location: the summing belongs in `Docker.Observer` next to `fetch_volume_sizes/0`; the styling hook is already there in `sidebar.ex:volume_item` (`@vol.size` renders the text).

6. **Read-only agent awareness tool.** Agents sharing a workspace don't know about each other. If Agent A rebuilds containers while Agent B is mid-deploy, B sees mysterious failures with no explanation. A read-only `workspace_agents` MCP tool that returns `[{name, status, last_action}]` (same data the sidebar shows, just an ETS lookup) would let agents say "another agent just rebuilt" instead of silently failing. No spawning, no cross-agent messaging, no control — just awareness. The security boundary (no `Tools.Agents`, no spawn) stays intact.

9. **LifecycleE2ETest "destroy leaves no residue" — supervisor stays alive past 90s on CI.** `WorkspaceSupervisor.workspace_running?(ws_id)` continues to report `true` for over 90 seconds after `Workspace.Destructor.destroy/1` returns on the docker-e2e CI runner. Either `DynamicSupervisor.terminate_child` is hanging on a Docker daemon ack inside `ServiceManager.terminate/2`, or some path is recreating the WorkspaceGroup after teardown (Setup task respawn? source_children?). Test currently `@tag :skip`'d in `test/loopyard/workspace/lifecycle_e2e_test.exs:78`. Reproduce: run `mix test test/loopyard/workspace/lifecycle_e2e_test.exs --include skip --include docker` against a real Docker daemon, then add `Logger` traces around terminate_child + Registry.lookup loops to see who's recreating the entry.

7. **Consider SQLite + Ecto for persistent state (later).** Today ETS + an append-only ETF log per workspace is the storage substrate. Works fine at current scale but cross-cuts: registry persistence (`project_store.ex` → JSON), agent messages (`agent_log.ex` → ETF), projects/workspaces (`workspace_registry.ex` → ETS), secrets (`secrets.ex` → JSON) each have bespoke persistence paths. SQLite via Ecto would give us a single queryable store, real transactions, trivial backups, and compaction-for-free. Not urgent — the current setup is fast and has no real bugs pointing at it. Revisit when (a) we want cross-workspace queries ("show every agent that used this secret"), (b) log compaction + migration machinery starts feeling more complex than a schema, or (c) we add multi-node features that need a shared store. Keeping `ProjectStore` / `AgentLog` / `WorkspaceRegistry` as narrow interfaces (not leaking ETS semantics to callers) now makes a later swap tractable — we're already doing that.

## ACP backend caveats (ACP is now the default)

`Harness.ACP` is now the default backend (`config :loopyard, :default_harness: Loopyard.Harness.ACP`; test.exs stays on `Harness.Fake`; the host-execution `Harness.Claude` is deleted). Cancel (`session/cancel`), resume (`session/load`), and system-prompt threading (#17 partial) landed. The remaining items below are now **known caveats of the default**, not blockers — the two that matter most for parity are #13 (human-gated permissions) and the #17 tool-policy/mcp_servers threading.

13. **Plumb `session/request_permission` through to a real decision.** `Connection.handle_agent_request("session/request_permission", …)` surfaces a `%Event.PermissionRequest{}` but `StreamHandler.process_event/2` has no clause for it — it falls through `process_event(_other, state)` and is **dropped**, so the UI never sees it. Meanwhile `ACP.acp_permission_mode/1` hardcodes `:auto_allow` (Connection picks the first `allow*` option). Wire the event into StreamHandler → an approval card (reuse the `Harness.Approvals` broker), and add the `:ask` permission mode (#7) so a human gates the call instead of auto-allowing. Until then, an ACP agent is bounded only by the container sandbox, not per-tool policy (see SECURITY.md → ACP adapter trust boundary).

16. **Token accounting fixed; dollar cost still zeroed.** With claude-agent-acp@0.60.0 the Translator consumes `usage_update` notifications: `input_tokens` is the session's REAL context usage, so `context_utilization` moves and the 92% proactive compaction + context warnings work under ACP (this was the root enabler of the old OOM death spiral, now also broken by the mid-turn-crash compaction breaker in `chat_agent.ex`). Output tokens remain a byte-estimate and `cost_usd` stays 0.0 — the adapter doesn't price turns. Containers stamped from the pre-v2 image emit no `usage_update` and behave as before until re-stamped.

17. **`session_opts` are ClaudeCode-shaped and not fully threaded to ACP.** _Mostly done:_ the **system prompt** reaches the harness (`maybe_install_system_prompt/2` installs `append_system_prompt`/`system_prompt` as `CLAUDE.local.md`), and **`mcp_servers`** now landed — Loopyard's control-plane tools reach an in-container ACP agent over a dedicated HTTP MCP bridge (`Loopyard.MCP` / `LoopyardWeb.MCP.{Server,Listener}`, `ToolConfig.acp_mcp_servers/2`), threaded as `:acp_mcp_servers` → `session/new` `mcpServers`, bearer-authed + agent-scoped (see SECURITY.md → ACP MCP bridge). **Still open:** (a) **tool policy** — `allowed_tools`/`disallowed_tools` have no ACP equivalent; map them onto the permission model (auto-reject disallowed / auto-allow allowed inside `decide_permission`), which depends on the `:ask` work (#13). (c) `thinking`/`max_turns` have no ACP equivalent — document as dropped. Until (a) lands, an ACP agent runs with the harness's tool defaults for *native* tools, though Loopyard's MCP tools are now available.

19. **Verify the ACP↔MCP bridge against a real in-container agent, and refine its prompt.** The bridge is unit-tested and verified over real HTTP (unauth → 401, `initialize`, `tools/list`, `tools/call` dispatch + identity binding), but the final link — `claude-code-acp@0.16.2` actually *connecting* to an HTTP `mcpServers` entry and exposing those tools to the model — needs an end-to-end check with a live workspace container (requires an in-container inference credential). Two follow-ups once that's confirmed: (a) the in-container agent's `CLAUDE.local.md` still tells it to use `mcp__loopyard-container__exec`/`read_file` for "ALL work", but the bridge only exposes the control-plane subset — the in-container prompt should point fs/exec at the *native* tools and reserve MCP for control-plane. (b) Per-agent token revocation on agent death (today the signed token is valid until max-age, scoped to one workspace).

18. **Untested guardrails on the ACP fs delegation (host mode).** `Connection.handle_agent_request("fs/read_text_file" | "fs/write_text_file", …)` passes the adapter-supplied `path` straight to `File.read/1` / `File.write/2` with **no `validate_workspace_path` clamp** — host mode trusts the adapter with the host filesystem, and there's no test proving a `../../etc/passwd`-style path is rejected (because nothing rejects it yet). In-container mode advertises no fs capability so this path is unused there, which is why it's tolerable for now. Before host mode is anything but a spike: clamp both handlers through `Helpers.validate_workspace_path/1` and add a rejection test mirroring `write_file_test.exs`. Also missing: a bounded-buffer test for `Transport.Port` (the `:noeol` continuation buffer has no hard ceiling — a pathological adapter can grow `state.buf` unboundedly).

22. **ACP rate-limit handling: push-first, stderr classification as fallback.** Diagnosed live (agent `bc17dbb4450d553a`, 2026-07-20): an upstream "API Error: Rate limit reached" makes the adapter error the `session/prompt` request and EXIT (status 1) — pre-fix that read as a generic crash, and restart-with-resume looped straight back into the hard limit. Two layers now: (1) claude-agent-acp@0.60.0 PUSHES `usage_update` + `_claude/rateLimit` (status, `resetsAt` ms, type) mid-turn → Translator emits a full `%Event.RateLimitStatus{}` → precise timed retry, and an `allowed` push un-parks the agent immediately. (2) Fallback for the adapter-death shape (and pre-v2 containers): `Connection` classifies the prompt-error reply + rate-limit stderr on `{:acp_closed, …}` and emits a `:rejected` with nil reset → 60s poll. The nil-reset poll now only matters on the fallback path; adapter emits the push only after the session has assistant usage (`lastAssistantTotalUsage !== null`), which is why the fallback stays.

23. **Classify the harness 401 (unauthenticated CLI) as a distinct, actionable error — not a generic crash.** Diagnosed live (2026-07-20): the identity's `~/.loopyard/env` lost `CLAUDE_CODE_OAUTH_TOKEN` (see the `Env` store-decay fix — atomic write + non-clobbering read), so the in-container `claude` 401'd and the adapter EXITED on every `session/prompt`. That surfaced as `"CLI crashed — restarting and resuming where it left off"` + `"Turn failed — tap Send to retry"` — identical to a memory/resume crash, so debugging chased resume/compaction logic for hours when the fix was "put the token back." The adapter's stderr on an auth failure is distinctive ("Not logged in" / 401 / "Please run /login"); `Connection` should classify it the way it classifies rate-limit stderr (#22) and emit a dedicated `:auth_expired`-style event so ChatAgent renders the WHY/CONSEQUENCE/ACTION error it already has for auth ("Claude isn't authenticated in this workspace → every turn will crash → push a fresh `CLAUDE_CODE_OAUTH_TOKEN` on the Workstation page"). Bonus: before giving up, ChatAgent could run one `Env.sync_home/1` — if the store has the token but the container's env is stale (exactly this incident), that self-heals without any human action. Would have turned a multi-hour hunt into a one-line diagnosis.

24. **ACP orphan reap can kill a SIBLING agent's live long session (shared work container).** The launch-time sweep in `acp.ex` kills any claude-cmdline process older than `@reap_min_age_s` (150s). Age distinguishes "mid-handshake" from "orphan," but NOT "busy for an hour" from "orphan" — so when two agents share one work container, agent B (re)launching sweeps away agent A's live mid-turn adapter. Single-agent containers are safe (the only old process IS the orphan being replaced), which is why this hasn't bitten loudly yet. Better discriminator than age: **parentage** — a truly orphaned `claude` child reparents to PID 1 (docker-init), while a live adapter runs with the exec runtime's ppid 0 and a live `claude` child has the adapter as its parent. Kill ppid==1 claude processes at any age; for stale exec'd adapters (ppid 0, host client gone) keep the age guard but ALSO require no live stdin (or exclude pids of sessions Loopyard knows are alive, if the adapter ever reports its in-container pid). Related: the stream stall watchdog (commit on main) removed the other busy-harness killer — the absolute 10-min turn ceiling.

25. **Codex device-code login as an in-chat card (ACP URL elicitation).** `codex-acp` advertises a `chat-gpt-device-code` auth method **only when the client declares URL-elicitation support** (`clientCapabilities.elicitation.url`); it then answers `authenticate` with an `elicitation/create` carrying the verification URL + one-time code, and completes on its own once the user enters it. Loopyard already advertises FORM elicitation for questions; adding URL elicitation (a card with the link + code, routed like a question) would let a phone-only user sign a Codex agent in from the chat — no console, no token to paste. Until then the path is `codex login --device-auth` in the box console (`Workstation.Integration`). Note `Connection.Auth`'s headless allowlist must NOT pick this method automatically — it needs a human — but a `:needs_login` event pointing at the card would.

26. **Live model list for the Codex picker.** `Catalog` pins no Codex model ids on purpose (they move weekly and `set_model` REJECTS unknown ids), so the picker offers only "Adapter default" for Codex. The session already carries the adapter's real list (`Connection.available_models/1`, both `models` and `configOptions` dialects) — expose it on the agent summary and render it under the Codex optgroup for the *current* harness, keeping the pinned list only for the harness that isn't running. Same move gives Claude the CLI's live aliases as a fallback.

27. **Adapter pins move near-daily — decide a bump cadence.** `@agentclientprotocol/codex-acp` cuts a release most days (1.6.0 pinned 2026-08-20; 1.8.0 on 2026-09-01 with codex 0.152 + session forks + MCP OAuth) and bundles its own `@openai/codex`, while the Dockerfile ALSO installs `@openai/codex` at whatever npm serves at build time — two Codex binaries per image. Pick one: drop the separate `@openai/codex` install and let the adapter's bundled one be the box's `codex` (set `CODEX_PATH` if the console needs the same binary), and bump both adapters together with an image tag bump on a schedule rather than ad hoc.

## Performance

10. **Cache `resolve_container` / `agent_container` resolution per turn.** Every container tool call (`exec`/`grep`/`glob`/`tree`/`file_info`/`logs`/`ports`) now resolves its target via `Workspace.agent_container/1`, which does up to two `docker inspect` calls (compose container, then the cheap `WorkContainer`). That's correct but adds ~20–60ms per tool call on a hot agent loop. Cheap win: memoize the resolved container name on the agent's ETS state, invalidated when preview is started/stopped (those are the only transitions that change which container is the exec target). Keep the lazy `ensure_working/1` self-heal on cache miss.

21. **Chat transcript: LiveView streams / real pruning.** The lazy half of [Epic #67](https://github.com/loopyard/loopyard/issues/67) shipped — `Messages.ToolResults` renders a tool-result body only while expanded (live tail, errors, or a viewer's click; `lazy?/1` + `result_expanded?/1` in `tool_results.ex`), so collapsed scrollback no longer holds thousands of highlighted nodes. Still open from the epic: move the transcript to LiveView streams with `limit:` so the 160-message window prunes nodes from the DOM rather than re-rendering the whole list, plus the measurement harness that proves it. Pairs with #8 (pagination).

8. **Paginate chat messages (load recent, fetch older on scroll-up).** Currently all messages are rendered into the DOM on mount (400+ for long-lived agents). At scale this will bog down both the server (serializing the full list) and the browser (laying out hundreds of nodes). Load the last ~50 messages on mount, prepend older batches when the user scrolls to the top. Hard parts: maintaining scroll position when prepending content, coordinating with LiveView's DOM diffing, and deciding the fetch boundary (ETS slice vs. cursor). The `ScrollBottom` hook already tracks scroll position — extend it to detect "at top" and `pushEvent` to request more.

## Product vision

12. **Weave Aural (ambient sound) into the workspace experience.** _Partially shipped:_ a persistent app-wide ambient bed now lives in the root layout (`root.html.heex` `#ambient` + the `AmbientAudio` app.js hook), and the whole app runs in one `live_session` so the bed survives navigation. Off by default (autoplay policy); a corner toggle starts it and the choice persists in localStorage. It streams the global `activity` channel, which `ActivitySound` already drives from live agent events. **Still open:** (a) per-scope channels — switch the bed to `project-<id>` as you enter a project so each sounds distinct (today it's one global channel for continuity; changing `src` restarts the stream, so a crossfade is needed); (b) per-participant mute/volume beyond the on/off toggle (it's multiplayer — one person's audio ≠ everyone's; a volume slider + the two-channel proximity mix `ActivitySound` already emits); (c) richer signal→bed mapping (decision-waiting vs build-running distinct textures). Lives near the collaborative-listening direction (Presence + per-room channel) already sketched for Aural.

13. **Cascading TTL — let the system fall asleep in tiers.** The town-hall line
    (`/notifications`, `Loopyard.Attention`) already self-decays: an unanswered question
    ages out on its TTL (the brokers reap dead waiters). Extend that decay
    upward: a question times out → after its own idle TTL a *workspace* with no
    live attention falls asleep (cluster down, agent CLI reaped) → after a longer
    TTL the whole *project* idles down. Accessing any tier spins it back up
    lazily and it drifts back to sleep when you leave. The point is resource
    efficiency without manual lifecycle management — the system uses what it
    needs and releases the rest on its own. Build on the existing idle reaper
    (`ChatAgent.IdleReaper`) + `Harness.MemoryMonitor`; the new piece is the
    tiered cascade + lazy wake. (Deferred deliberately until the queue UI proved
    out.)

14. **Global "needs you" badge — the town hall, reachable from anywhere.** `/notifications`
    exists and is tear-out-able, but you still have to navigate to it. Add a
    small always-present count badge (app-wide chrome) that shows the blocking-item
    count and links to `/notifications`, so from any page you can see "3 agents waiting"
    and jump. Cleanest wiring: an `on_mount` hook on the `:app` live_session that
    subscribes to global activity + assigns the count, rendered as a floating
    element in `app.html.heex`. Keep it defensive (rescue, safe default) — it runs
    on every page, so a crash there freezes everything.

9. **Tool cards: rich visual previews for every tool call.** Each tool call in the chat should be a compact, visual window into what the agent is doing — not raw text dumps. DiffView (syntax-highlighted diffs for edits) is the first. Future cards: terminal output (exec — looks like a mini terminal), search results (grep — highlighted matches in context), file viewer (read — syntax-highlighted code), git log (commit list), browser screenshots (headless browser). Each card type has a compact (inline chat) and expanded (full-screen) mode. Clicking a card opens the full view. Same rendering components power both. The code browser / file viewer / git viewer are standalone product surfaces; the chat embeds previews that link into them.

## How to work this list

- Pick the lowest-numbered open item in the category you're targeting. Ordering within a category encodes "simpler first."
- One commit per item. Keep the scope tight — if an item grows, split it.
- When done, delete the entry from this file in the same commit (or the follow-up if cleanup was forgotten).
- Items can be added by anyone; new entries go to the bottom of their category so ordering stays stable.
- If an item needs more than a paragraph of design (scope cuts, data shapes, migration path), drop a scoped plan into `plans/<name>.md` and move the entry here to the "In flight" section with a link. Delete the plan file when it ships, or archive it if the decision informs future work.
- When you ship behavior, update the doc that owns the concern in the same commit. See the "Update docs when you ship a major change" rule in `CLAUDE.md`.

## Attention: pending cards without live waiters must stay in the line
`Attention.line` (feeds /operator "For you" + /notifications) lists only items with a
live waiter; `Questions.pending_all` prunes dead waiters and marks the card
:timeout. But the queued model means a card can be answerable long after its
waiter died (answers persist + reach the agent). Result: the longest-waiting
questions vanish from "For you" and the human has to hunt (gbrain incident,
Jul 25). Fix: source the line from PENDING CARDS in the message store (role
:question/:secret/:approval, status :pending), waiter-or-not; answering a
waiterless card records + informs the agent on its next turn. Also: Digest
should append a "needs input" entry when a question posts, and the operator
prompt should tell it to surface unanswered questions proactively — the chief
of staff hunts so the human doesn't.

## Source-audit follow-ups (Jul 2026 audit)

1. **Unify the two session-restart paths.** `restart_session_now/2` and the
   `:auto_restart_context` cast do the same job (stop → fresh session → seed →
   re-drive) through different primitives: only the former tracks the OS pid,
   clears `auth_error`, and schedules a backoff retry on failure; the latter
   hand-rolls `backend.stop` and just resets to `:idle` with no retry. A fix
   applied to one will not reach the other — the highest structural drift risk
   in ChatAgent. Collapse `:auto_restart_context` onto the `restart_session_now`
   path (it only additionally needs the re-send prompt + seed).
2. **Case-table complexity**: `LoopyardWeb.Components.ToolSummary.summarize`
   (CC 74) is a giant case tree — convert to data (a module-attribute map) so
   adding a tool is a row, not a clause. Low risk, cosmetic-mechanical.
   (`Viewers.FileType` already went data-driven — `@text_extensions` & co.)
3. **Property-based tests still absent** despite TESTING.md prescribing
   StreamData for `StreamBuffer`, `AgentLog` replay, `StateMachine`, and tool
   input validators. Zero `ExUnitProperties` usages in test/.
6. **Detail-panel action buttons feel dominant.** Brad's parked call
   (Jul 2026): keep the labeled slabs for now — icon-only + tooltips is
   mobile-hostile (no hover), and the labels are the safety on Restart/Remove.
   If they get revisited: icon + one-word label compacts, and/or demote the
   rare actions (Console, Close Port) behind a "⋯" overflow so frequency sets
   the hierarchy. The workspace agent already covers these ops via
   docker_compose/ports, so the buttons are the fast path, not the only path.

7. **The Reviewer deck prints identity twice on whole-card decisions.** Each
   deck section renders a `FocusedView.subject` naming project · workspace,
   and an approval / secret / settled-question card renders its OWN identity
   chip inside its band — so "gbrain · main" appears twice, ~40px apart, at
   two different sizes. Only the `question_block` branch avoids it (it's a
   bare block, so the deck supplies its chrome). Wanted: a way for a whole
   card to suppress its chip when its container already named the subject —
   the same `chrome={:desktop}` idea applied to identity. Not done here
   because `question_card`/`approval_card`/`secret_card` render into the chat
   stream too, where the chip is the ONLY identity and must stay.

8. **`WorkspaceGroup` is still `strategy: :one_for_all`** (`workspace_group.ex`,
   `Supervisor.init/2`). Left over from the post-migration audit (HIGH #3, now
   in `plans/archive/post-migration-audit.md`): one crashing child —
   ContainerMonitor, the checkpointer, a source child — restarts the whole
   group, ServiceManager and every agent included, so an unrelated crash
   costs the user every harness in the workspace. The children don't share
   state that requires restarting together; `:one_for_one` (or `:rest_for_one`
   with ServiceManager first) with the same `max_restarts: 10, max_seconds: 60`
   budget is the fix. Verify with a crash-one-child test that asserts the
   agents' pids survive.

9. **`RestartController.release/1` docstring lies.** The moduledoc says release
   "clears the flag and respawns the agent via the normal start_agent path";
   the function only clears the quarantine fields in ETS, purges crash
   history, and publishes `Released` — nothing respawns (the function's own
   comment says leaving it to the operator is deliberate). Either make the
   docstring say that, or make `/system/quarantine`'s release button offer the
   respawn explicitly. A reader trusting the doc will click Release and wait
   for an agent that never comes back.

10. **`Attention.line/1` takes a `host` it ignores.** `def line(_host \\ nil)`
    (`attention.ex`) — paths stopped depending on the host when the inbox
    moved to `Notifications`, but `dashboard_live.ex` and `operator_live.ex`
    still compute and pass one. Drop the parameter and the two call-site
    lookups (and check `counts_by_workspace/1`, which still takes it) so the
    signature stops implying a dependency that doesn't exist.

## Security

1. **The SSH daemon is unauthenticated and bound to every interface.**
   `Loopyard.SSHServer` starts unconditionally from `application.ex` (there is
   no off switch — `SSH_PORT` unset means `0`, i.e. the OS picks a free port,
   not "disabled"), with `no_auth_needed: true` and an `:ssh.daemon/2` call
   that passes no `ip:` option, so it listens on all interfaces. Username =
   container name, no password — anyone who can reach the host on the LAN and
   find the port (random is not hidden; a scan finds it) gets a shell in any
   container. App auth is deferred by design (local-only trust), but this is
   the one listener that is reachable off-box AND grants exec. The fix is
   already specified in `plans/ssh-integration.md`: bind the local daemon to
   `127.0.0.1`, and require public-key auth (`no_auth_needed: false` +
   enrolled `authorized_keys`) for the network daemon. Ship the loopback bind
   now; it is one option in `ssh_opts`.
