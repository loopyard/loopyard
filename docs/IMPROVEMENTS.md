# Improvements backlog

A prioritized list of known, scoped improvements for BoomLooper. Ordered within each section by blast-radius-per-effort. When you pick one up, move it to "In progress" at the top of the file (or delete when done and link the commit).

## Reliability (prevents user-visible outages)

1. **Docker retry at the CLI layer.** `Docker.docker/2` fails hard on any transient error (daemon restart, socket hiccup, colima pause). A small retry-with-backoff wrapper absorbs most of those without leaking into every call site. Pair with a circuit breaker so we don't hammer a dying daemon.

## Simplicity (less to read, less to misunderstand)

2. **Split the big modules.** `ChatAgent` (~1000 lines) mixes session management, message persistence, streaming, ETS, boot recovery, and restart logic. `chat_live.ex` (~1200 lines) is handle_event/handle_info soup. Extract by concern — no behavior change, just visibility. Every new feature in those files costs more than the last one.

3. **One config story.** Settings live in env vars, `~/.boomlooper/`, `workspace.json`, `.boomlooper/workspace/`, compose files, and hardcoded module attributes. Write `docs/CONFIG.md` mapping every knob and, where cheap, collapse duplicate stores.

## Robustness (handles edge cases gracefully)

4. **Explicit agent state machine.** Statuses (`:booting`, `:idle`, `:thinking`, `:stopped`, `:crashed`, `:destroying`) are set from many call sites and checked by eyeballing. Owning transitions in one module (`transition(:booting, :started) -> :idle`) makes illegal states unrepresentable. The "remove agent → restart Claude → remove again" race hints at this gap.

5. **End-to-end integration test.** 300+ unit tests, zero end-to-end. Add one test that spawns a ChatAgent, writes a compose, runs `docker compose up`, execs a command, reads output, tears down. Gated behind `--include docker` so it doesn't slow the fast suite. Catches lifecycle regressions that unit tests by construction can't see.

6. **Volume disk usage visible and bounded.**

7. **Consider SQLite + Ecto for persistent state (later).** Today ETS + an append-only ETF log per workspace is the storage substrate. Works fine at current scale but cross-cuts: registry persistence, agent messages, projects, workspace metadata each have bespoke persistence paths. SQLite via Ecto would give us a single queryable store, real transactions, trivial backups, and compaction-for-free. Not urgent — the current setup is fast and has no real bugs pointing at it. Revisit when (a) we want cross-workspace queries, (b) log compaction + migration machinery starts feeling more complex than a schema, or (c) we add multi-node features that need a shared store. No quota, no sidebar indicator, no warning. A runaway agent writes until Docker errors with an opaque message. First step: size badge next to each volume in the sidebar. Next step: soft quota per workspace with a clear message on exceed.

## How to work this list

- Pick the lowest-numbered open item in the category you're targeting. Ordering within a category encodes "simpler first."
- One commit per item. Keep the scope tight — if an item grows, split it.
- When done, delete the entry from this file in the same commit (or the follow-up if cleanup was forgotten).
- Items can be added by anyone; new entries go to the bottom of their category so ordering stays stable.
