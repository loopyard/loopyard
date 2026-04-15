# Improvements backlog

A prioritized list of known, scoped improvements for BoomLooper. Ordered within each section by blast-radius-per-effort. When you pick one up, move it to "In progress" at the top of the file (or delete when done and link the commit).

## Simplicity (less to read, less to misunderstand)

1. **One config story.** Settings live in env vars, `~/.boomlooper/`, `workspace.json`, `.boomlooper/workspace/`, compose files, and hardcoded module attributes. Write `docs/CONFIG.md` mapping every knob and, where cheap, collapse duplicate stores.

2. **Continue splitting the big modules.** `ChatAgent` (~960 lines) and `chat_live.ex` (~1280 lines) still mix too many concerns. OSProcess was extracted and section-header comments were added for navigation, but the clearest remaining wins are: pull stream-event `handle_info` clauses into `ChatAgent.Streaming`, pull the `init_fresh` / `init_resume` / `start_session` boot path into `ChatAgent.Boot`, and pull the sync + diff `handle_event` clusters in chat_live into their own modules. Each is a moderate, well-scoped refactor; do one at a time to keep diffs reviewable.

## Robustness (handles edge cases gracefully)

3. **Explicit agent state machine.** Statuses (`:booting`, `:idle`, `:thinking`, `:stopped`, `:crashed`, `:destroying`) are set from many call sites and checked by eyeballing. Owning transitions in one module (`transition(:booting, :started) -> :idle`) makes illegal states unrepresentable. The "remove agent → restart Claude → remove again" race hints at this gap.

4. **End-to-end integration test.** 300+ unit tests, zero end-to-end. Add one test that spawns a ChatAgent, writes a compose, runs `docker compose up`, execs a command, reads output, tears down. Gated behind `--include docker` so it doesn't slow the fast suite. Catches lifecycle regressions that unit tests by construction can't see.

5. **Volume disk usage visible and bounded.** No quota, no sidebar indicator, no warning. A runaway agent writes until Docker errors with an opaque message. First step: size badge next to each volume in the sidebar. Next step: soft quota per workspace with a clear message on exceed.

6. **Consider SQLite + Ecto for persistent state (later).** Today ETS + an append-only ETF log per workspace is the storage substrate. Works fine at current scale but cross-cuts: registry persistence, agent messages, projects, workspace metadata each have bespoke persistence paths. SQLite via Ecto would give us a single queryable store, real transactions, trivial backups, and compaction-for-free. Not urgent — the current setup is fast and has no real bugs pointing at it. Revisit when (a) we want cross-workspace queries, (b) log compaction + migration machinery starts feeling more complex than a schema, or (c) we add multi-node features that need a shared store.

## How to work this list

- Pick the lowest-numbered open item in the category you're targeting. Ordering within a category encodes "simpler first."
- One commit per item. Keep the scope tight — if an item grows, split it.
- When done, delete the entry from this file in the same commit (or the follow-up if cleanup was forgotten).
- Items can be added by anyone; new entries go to the bottom of their category so ordering stays stable.
