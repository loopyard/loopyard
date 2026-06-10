# Improvements backlog

A prioritized list of known, scoped improvements for Loopyard. Ordered within each section by blast-radius-per-effort. When you pick one up, move it to "In progress" at the top of the file (or delete when done and link the commit).

## Simplicity (less to read, less to misunderstand)

2. **Continue splitting workspace_live handler clusters (if they grow).** Git diff and file browser are out (`DiffLoader`, `FileBrowser`). Sync and cluster-control clusters were reviewed and judged too thin to earn modules — section comments are enough. Revisit if either grows meaningfully.

## Robustness (handles edge cases gracefully)

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

## Performance

10. **Cache `resolve_container` / `agent_container` resolution per turn.** Every container tool call (`exec`/`grep`/`glob`/`tree`/`file_info`/`logs`/`ports`) now resolves its target via `Workspace.agent_container/1`, which does up to two `docker inspect` calls (compose container, then the cheap `WorkContainer`). That's correct but adds ~20–60ms per tool call on a hot agent loop. Cheap win: memoize the resolved container name on the agent's ETS state, invalidated when preview is started/stopped (those are the only transitions that change which container is the exec target). Keep the lazy `ensure_working/1` self-heal on cache miss.

8. **Paginate chat messages (load recent, fetch older on scroll-up).** Currently all messages are rendered into the DOM on mount (400+ for long-lived agents). At scale this will bog down both the server (serializing the full list) and the browser (laying out hundreds of nodes). Load the last ~50 messages on mount, prepend older batches when the user scrolls to the top. Hard parts: maintaining scroll position when prepending content, coordinating with LiveView's DOM diffing, and deciding the fetch boundary (ETS slice vs. cursor). The `ScrollBottom` hook already tracks scroll position — extend it to detect "at top" and `pushEvent` to request more.

## Product vision

9. **Tool cards: rich visual previews for every tool call.** Each tool call in the chat should be a compact, visual window into what the agent is doing — not raw text dumps. DiffView (syntax-highlighted diffs for edits) is the first. Future cards: terminal output (exec — looks like a mini terminal), search results (grep — highlighted matches in context), file viewer (read — syntax-highlighted code), git log (commit list), browser screenshots (headless browser). Each card type has a compact (inline chat) and expanded (full-screen) mode. Clicking a card opens the full view. Same rendering components power both. The code browser / file viewer / git viewer are standalone product surfaces; the chat embeds previews that link into them.

## How to work this list

- Pick the lowest-numbered open item in the category you're targeting. Ordering within a category encodes "simpler first."
- One commit per item. Keep the scope tight — if an item grows, split it.
- When done, delete the entry from this file in the same commit (or the follow-up if cleanup was forgotten).
- Items can be added by anyone; new entries go to the bottom of their category so ordering stays stable.
- If an item needs more than a paragraph of design (scope cuts, data shapes, migration path), drop a scoped plan into `plans/<name>.md` and move the entry here to the "In flight" section with a link. Delete the plan file when it ships, or archive it if the decision informs future work.
- When you ship behavior, update the doc that owns the concern in the same commit. See the "Update docs when you ship a major change" rule in `CLAUDE.md`.
