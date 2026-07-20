# Improvements backlog

A prioritized list of known, scoped improvements for Loopyard. Ordered within each section by blast-radius-per-effort. When you pick one up, move it to "In progress" at the top of the file (or delete when done and link the commit).

## Simplicity (less to read, less to misunderstand)

2. **Continue splitting workspace_live handler clusters (if they grow).** Git diff and file browser are out (`DiffLoader`, `FileBrowser`). Sync and cluster-control clusters were reviewed and judged too thin to earn modules — section comments are enough. Revisit if either grows meaningfully.

## Robustness (handles edge cases gracefully)

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

9. **LifecycleE2ETest "destroy leaves no residue" — supervisor stays alive past 90s on CI.** `WorkspaceSupervisor.workspace_running?(ws_id)` continues to report `true` for over 90 seconds after `Workspace.Destructor.destroy/1` returns on the docker-e2e CI runner. Either `DynamicSupervisor.terminate_child` is hanging on a Docker daemon ack inside `ServiceManager.terminate/2`, or some path is recreating the WorkspaceGroup after teardown (Setup task respawn? source_children?). Test currently `@tag :skip`'d in `test/loopyard/workspace/lifecycle_e2e_test.exs:67`. Reproduce: run `mix test test/loopyard/workspace/lifecycle_e2e_test.exs --include skip --include docker` against a real Docker daemon, then add `Logger` traces around terminate_child + Registry.lookup loops to see who's recreating the entry.

7. **Consider SQLite + Ecto for persistent state (later).** Today ETS + an append-only ETF log per workspace is the storage substrate. Works fine at current scale but cross-cuts: registry persistence (`project_store.ex` → JSON), agent messages (`agent_log.ex` → ETF), projects/workspaces (`workspace_registry.ex` → ETS), secrets (`secrets.ex` → JSON) each have bespoke persistence paths. SQLite via Ecto would give us a single queryable store, real transactions, trivial backups, and compaction-for-free. Not urgent — the current setup is fast and has no real bugs pointing at it. Revisit when (a) we want cross-workspace queries ("show every agent that used this secret"), (b) log compaction + migration machinery starts feeling more complex than a schema, or (c) we add multi-node features that need a shared store. Keeping `ProjectStore` / `AgentLog` / `WorkspaceRegistry` as narrow interfaces (not leaking ETS semantics to callers) now makes a later swap tractable — we're already doing that.

## Robustness (continued)

11. **Migrate the ACP adapter off the deprecated package.** The work-container base image (`priv/workspace-base/Dockerfile`) pins `@zed-industries/claude-code-acp@0.16.2`, which npm reports as renamed to `@agentclientprotocol/claude-agent-acp` (bin `claude-agent-acp`). Validated working at 0.16.2, but migrate before it stops receiving updates: bump the package + bin name in the Dockerfile, update the `claude-code-acp` references in `work_container_test.exs` and (when wired) the ACP backend's `docker_exec_cmd`. Pin the new version deliberately; re-run the in-container handshake test.

## ACP backend caveats (ACP is now the default)

`Harness.ACP` is now the default backend (`config :loopyard, :default_harness: Loopyard.Harness.ACP`; test.exs stays on `Harness.Fake`, and `Harness.Claude` is selectable per-agent via `backend:` and one config line away). Cancel (#14), resume (#15), and system-prompt threading (#17 partial) landed. The remaining items below are now **known caveats of the default**, not blockers — the two that matter most for parity are #13 (human-gated permissions) and the #17 tool-policy/mcp_servers threading.

13. **Plumb `session/request_permission` through to a real decision.** `Connection.handle_agent_request("session/request_permission", …)` surfaces a `%Event.PermissionRequest{}` but `StreamHandler.process_event/2` has no clause for it — it falls through `process_event(_other, state)` and is **dropped**, so the UI never sees it. Meanwhile `ACP.acp_permission_mode/1` hardcodes `:auto_allow` (Connection picks the first `allow*` option). Wire the event into StreamHandler → an approval card (reuse the `Harness.Approvals` broker), and add the `:ask` permission mode (#7) so a human gates the call instead of auto-allowing. Until then, an ACP agent is bounded only by the container sandbox, not per-tool policy (see SECURITY.md → ACP adapter trust boundary).

14. ~~**No `session/cancel` interrupt.**~~ **DONE.** `Harness.cancel_turn/1` was already the behaviour callback (wired through `Turn` + `ChatAgent.warm_interrupt`); only the ACP leaf was a no-op. `Connection.cancel/1` now sends the `session/cancel` notification (keeping the session warm), and `ACP.cancel_turn/1` calls it (exit-safe). Frame-level tested in `connection_test.exs`.

15. ~~**ACP resume is a no-op — no `session/load`.**~~ **DONE.** `handle_response(:initialize, …)` now issues `session/load` with the saved id when `:resume` is present AND the adapter advertised `agentCapabilities.loadSession`, falling back to `session/new` otherwise, and again if `session/load` errors (expired id). The resume id already round-trips (captured → `claude_session_id` → `:resume`). Frame-level tested in `connection_test.exs`. Still worth verifying replay behavior against the real adapter (history arrives as `session/update` with `turn == nil`, safely ignored).

16. **Token / cost accounting is zeroed.** `Translator.finish/2` emits a `%Event.SessionResult{}` with `input_tokens: 0, output_tokens: 0, cost_usd: 0.0` because claude-code-acp doesn't surface usage today (see the cost-visibility decision, #11). Context-window warnings and cost display are therefore inert under ACP. Track the upstream `_meta` usage field if/when the adapter adds it; until then, document that cost telemetry is unavailable on the ACP path so we don't silently report $0.

17. **`session_opts` are ClaudeCode-shaped and not fully threaded to ACP.** _Mostly done:_ the **system prompt** reaches the harness (`maybe_install_system_prompt/2` installs `append_system_prompt`/`system_prompt` as `CLAUDE.local.md`), and **`mcp_servers`** now landed — Loopyard's control-plane tools reach an in-container ACP agent over a dedicated HTTP MCP bridge (`Loopyard.MCP` / `LoopyardWeb.MCP.{Server,Listener}`, `ToolConfig.acp_mcp_servers/2`), threaded as `:acp_mcp_servers` → `session/new` `mcpServers`, bearer-authed + agent-scoped (see SECURITY.md → ACP MCP bridge). **Still open:** (a) **tool policy** — `allowed_tools`/`disallowed_tools` have no ACP equivalent; map them onto the permission model (auto-reject disallowed / auto-allow allowed inside `decide_permission`), which depends on the `:ask` work (#13). (c) `thinking`/`max_turns` have no ACP equivalent — document as dropped. Until (a) lands, an ACP agent runs with the harness's tool defaults for *native* tools, though Loopyard's MCP tools are now available.

19. **Verify the ACP↔MCP bridge against a real in-container agent, and refine its prompt.** The bridge is unit-tested and verified over real HTTP (unauth → 401, `initialize`, `tools/list`, `tools/call` dispatch + identity binding), but the final link — `claude-code-acp@0.16.2` actually *connecting* to an HTTP `mcpServers` entry and exposing those tools to the model — needs an end-to-end check with a live workspace container (requires an in-container inference credential). Two follow-ups once that's confirmed: (a) the in-container agent's `CLAUDE.local.md` still tells it to use `mcp__loopyard-container__exec`/`read_file` for "ALL work", but the bridge only exposes the control-plane subset — the in-container prompt should point fs/exec at the *native* tools and reserve MCP for control-plane. (b) Per-agent token revocation on agent death (today the signed token is valid until max-age, scoped to one workspace).

18. **Untested guardrails on the ACP fs delegation (host mode).** `Connection.handle_agent_request("fs/read_text_file" | "fs/write_text_file", …)` passes the adapter-supplied `path` straight to `File.read/1` / `File.write/2` with **no `validate_workspace_path` clamp** — host mode trusts the adapter with the host filesystem, and there's no test proving a `../../etc/passwd`-style path is rejected (because nothing rejects it yet). In-container mode advertises no fs capability so this path is unused there, which is why it's tolerable for now. Before host mode is anything but a spike: clamp both handlers through `Helpers.validate_workspace_path/1` and add a rejection test mirroring `write_file_test.exs`. Also missing: a bounded-buffer test for `Transport.Port` (the `:noeol` continuation buffer has no hard ceiling — a pathological adapter can grow `state.buf` unboundedly).

20. **ACP harness OOM death spiral on long conversations — compact on repeated mid-turn crash.** Diagnosed live (agent `07b22ffeb604debc`, 2026-07-20): the work container's hard 8GiB `--memory` cap OOM-killed the in-container harness **26 times** (`memory.events oom_kill`), accelerating to every-turn as the conversation grew (110 turns, 1000 msgs, one claude session). Chain: #16 zeroes `input_tokens` → `context_utilization` stays 0.0 → the 92% proactive compaction NEVER fires under ACP → the session grows unboundedly → each turn the harness loads/replays it and balloons past the cgroup cap → kernel kills it → recovery `resume:`s the SAME bloated session → next turn balloons again. Also explains slow Send→response: every send first respawns the harness + replays the giant session. Fix (designed, not yet shipped): (a) count mid-turn CLI deaths since the last CLEAN turn completion on a new state field (the existing 60s message-window breaker in `on_stream_error` misses crashes minutes apart, and `consecutive_crashes` belongs to the thinking-exit backoff machinery); at ≥2, route recovery to the existing `{:auto_restart_context, nil}` compaction (summarize → fresh session) instead of resume — that breaks the spiral with a real signal. (b) Longer term: estimate utilization under ACP (message bytes ÷ 4) so the proactive compaction fires BEFORE the first OOM. Note the orphan-adapter reaper in `harness/acp.ex` already bounds leaked exec pairs — accumulation wasn't the driver.

22. **ACP rate-limit classification landed — refine the no-reset-time retry cadence.** Diagnosed live (agent `bc17dbb4450d553a`, 2026-07-20): an upstream "API Error: Rate limit reached" makes claude-code-acp error the `session/prompt` request and EXIT (status 1) — pre-fix that read as a generic crash, and restart-with-resume looped straight back into the hard limit. Fixed: `Connection` classifies both shapes (prompt-error reply + rate-limit stderr on `{:acp_closed, …}`) and emits `%Event.RateLimitStatus{status: :rejected}` so the ChatAgent parks in `:rate_limited` (queue held, timed retry). Remaining refinement: ACP surfaces NO `resets_at_ms`, so `compute_rate_limit_wait_ms(nil)` polls every 60s — over a multi-hour cap that's one respawn + one "rate-limited" chat message per minute (the "first rejection" dedup resets each cycle). Consider a growing backoff for the nil-reset case and/or suppressing repeat chat messages within an hour.

## Performance

10. **Cache `resolve_container` / `agent_container` resolution per turn.** Every container tool call (`exec`/`grep`/`glob`/`tree`/`file_info`/`logs`/`ports`) now resolves its target via `Workspace.agent_container/1`, which does up to two `docker inspect` calls (compose container, then the cheap `WorkContainer`). That's correct but adds ~20–60ms per tool call on a hot agent loop. Cheap win: memoize the resolved container name on the agent's ETS state, invalidated when preview is started/stopped (those are the only transitions that change which container is the exec target). Keep the lazy `ensure_working/1` self-heal on cache miss.

21. **Collapsed tool cards keep their full bodies in the DOM — lazy-render on expand.** → **Promoted to [Epic #67](https://github.com/loopyard/loopyard/issues/67)** (chat DOM audit: lazy card bodies, LV-streams evaluation, pagination #8, measurement harness); details live there. Confirmed against a real long session (Safari tab at 2.5GB): the transcript window caps at 160 messages, but every closed `<details>` card (tool output, file read, grep) retains up to `@result_line_cap` (300) lines of content — syntax-highlighted file cards are thousands of DOM nodes each, collapsed or not. Hidden ≠ deallocated. Fix direction: render card bodies only when open (summary click → `phx-click` sets an expanded-set assign; body renders server-side on demand — ~50ms LAN roundtrip on first expand is fine), or move the transcript to LiveView streams with `limit:` so pruning genuinely removes nodes. Pairs with #8 (pagination).

8. **Paginate chat messages (load recent, fetch older on scroll-up).** Currently all messages are rendered into the DOM on mount (400+ for long-lived agents). At scale this will bog down both the server (serializing the full list) and the browser (laying out hundreds of nodes). Load the last ~50 messages on mount, prepend older batches when the user scrolls to the top. Hard parts: maintaining scroll position when prepending content, coordinating with LiveView's DOM diffing, and deciding the fetch boundary (ETS slice vs. cursor). The `ScrollBottom` hook already tracks scroll position — extend it to detect "at top" and `pushEvent` to request more.

## Product vision

12. **Weave Aural (ambient sound) into the workspace experience.** _Partially shipped:_ a persistent app-wide ambient bed now lives in the root layout (`root.html.heex` `#ambient` + the `AmbientAudio` app.js hook), and the whole app runs in one `live_session` so the bed survives navigation. Off by default (autoplay policy); a corner toggle starts it and the choice persists in localStorage. It streams the global `activity` channel, which `ActivitySound` already drives from live agent events. **Still open:** (a) per-scope channels — switch the bed to `project-<id>` as you enter a project so each sounds distinct (today it's one global channel for continuity; changing `src` restarts the stream, so a crossfade is needed); (b) per-participant mute/volume beyond the on/off toggle (it's multiplayer — one person's audio ≠ everyone's; a volume slider + the two-channel proximity mix `ActivitySound` already emits); (c) richer signal→bed mapping (decision-waiting vs build-running distinct textures). Lives near the collaborative-listening direction (Presence + per-room channel) already sketched for Aural.

9. **Tool cards: rich visual previews for every tool call.** Each tool call in the chat should be a compact, visual window into what the agent is doing — not raw text dumps. DiffView (syntax-highlighted diffs for edits) is the first. Future cards: terminal output (exec — looks like a mini terminal), search results (grep — highlighted matches in context), file viewer (read — syntax-highlighted code), git log (commit list), browser screenshots (headless browser). Each card type has a compact (inline chat) and expanded (full-screen) mode. Clicking a card opens the full view. Same rendering components power both. The code browser / file viewer / git viewer are standalone product surfaces; the chat embeds previews that link into them.

## How to work this list

- Pick the lowest-numbered open item in the category you're targeting. Ordering within a category encodes "simpler first."
- One commit per item. Keep the scope tight — if an item grows, split it.
- When done, delete the entry from this file in the same commit (or the follow-up if cleanup was forgotten).
- Items can be added by anyone; new entries go to the bottom of their category so ordering stays stable.
- If an item needs more than a paragraph of design (scope cuts, data shapes, migration path), drop a scoped plan into `plans/<name>.md` and move the entry here to the "In flight" section with a link. Delete the plan file when it ships, or archive it if the decision informs future work.
- When you ship behavior, update the doc that owns the concern in the same commit. See the "Update docs when you ship a major change" rule in `CLAUDE.md`.
