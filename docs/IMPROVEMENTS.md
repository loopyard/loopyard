# Improvements backlog

A prioritized list of known, scoped improvements for BoomLooper. Ordered within each section by blast-radius-per-effort. When you pick one up, move it to "In progress" at the top of the file (or delete when done and link the commit).

## Simplicity (less to read, less to misunderstand)

1. **Split chat_live.ex handler clusters.** `chat_live.ex` (~1280 lines) has three clusters of `handle_event` clauses with their own vocabulary that only touch assigns at the edges: git-diff viewer, source-adapter sync controls, and compose cluster controls. Extract each into its own module (pattern: same as `agent_lifecycle.ex`, which already did this for spawn/select). `ChatAgent` is **not** on this list — despite its size, it's one GenServer managing one session with interleaved state transitions; splitting it would be proximate complexity, not a real concern boundary. Section-header comments in `chat_agent.ex` are enough.

## Robustness (handles edge cases gracefully)

2. **Explicit agent state machine.** Statuses (`:booting`, `:idle`, `:thinking`, `:stopped`, `:crashed`, `:destroying`) are set from many call sites and checked by eyeballing. Owning transitions in one module (`transition(:booting, :started) -> :idle`) makes illegal states unrepresentable. The "remove agent → restart Claude → remove again" race hints at this gap.

3. **End-to-end integration test.** 300+ unit tests, zero end-to-end. Add one test that spawns a ChatAgent, writes a compose, runs `docker compose up`, execs a command, reads output, tears down. Gated behind `--include docker` so it doesn't slow the fast suite. Catches lifecycle regressions that unit tests by construction can't see.

4. **Volume disk usage visible and bounded.** No quota, no sidebar indicator, no warning. A runaway agent writes until Docker errors with an opaque message. First step: size badge next to each volume in the sidebar. Next step: soft quota per workspace with a clear message on exceed.

5. **Consider SQLite + Ecto for persistent state (later).** Today ETS + an append-only ETF log per workspace is the storage substrate. Works fine at current scale but cross-cuts: registry persistence, agent messages, projects, workspace metadata each have bespoke persistence paths. SQLite via Ecto would give us a single queryable store, real transactions, trivial backups, and compaction-for-free. Not urgent — the current setup is fast and has no real bugs pointing at it. Revisit when (a) we want cross-workspace queries, (b) log compaction + migration machinery starts feeling more complex than a schema, or (c) we add multi-node features that need a shared store.

## How to work this list

- Pick the lowest-numbered open item in the category you're targeting. Ordering within a category encodes "simpler first."
- One commit per item. Keep the scope tight — if an item grows, split it.
- When done, delete the entry from this file in the same commit (or the follow-up if cleanup was forgotten).
- Items can be added by anyone; new entries go to the bottom of their category so ordering stays stable.
