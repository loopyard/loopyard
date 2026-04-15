# Improvements backlog

A prioritized list of known, scoped improvements for BoomLooper. Ordered within each section by blast-radius-per-effort. When you pick one up, move it to "In progress" at the top of the file (or delete when done and link the commit).

## Simplicity (less to read, less to misunderstand)

1. **Continue splitting workspace_live handler clusters (if they grow).** Git diff and file browser are out (`DiffLoader`, `FileBrowser`). Sync and cluster-control clusters were reviewed and judged too thin to earn modules — section comments are enough. Revisit if either grows meaningfully.

## Robustness (handles edge cases gracefully)

2. **Migrate ChatAgent transition sites to `StateMachine.transition/2`.** The state graph and validator exist (`BoomLooper.ChatAgent.StateMachine`). The 20+ in-place `%{state | status: ...}` mutations in `ChatAgent` don't validate yet. Opportunistic migration: pass each through `transition/2`, log an `EventLog.warning` on `{:error, {:invalid_transition, from, to}}`, and if the move is genuinely illegal, fix the call site. Catches races like "remove agent → restart Claude → remove again."

3. **Soft volume quota.** Sidebar size badges exist; there's still no quota or warning threshold. When a workspace's total volume size crosses a configurable limit (default maybe 5 GB), surface an EventLog warning and show a red badge. Prevents "runaway agent fills disk" without needing hard limits that break legitimate large workspaces.

4. **Consider SQLite + Ecto for persistent state (later).** Today ETS + an append-only ETF log per workspace is the storage substrate. Works fine at current scale but cross-cuts: registry persistence, agent messages, projects, workspace metadata each have bespoke persistence paths. SQLite via Ecto would give us a single queryable store, real transactions, trivial backups, and compaction-for-free. Not urgent — the current setup is fast and has no real bugs pointing at it. Revisit when (a) we want cross-workspace queries, (b) log compaction + migration machinery starts feeling more complex than a schema, or (c) we add multi-node features that need a shared store.

## How to work this list

- Pick the lowest-numbered open item in the category you're targeting. Ordering within a category encodes "simpler first."
- One commit per item. Keep the scope tight — if an item grows, split it.
- When done, delete the entry from this file in the same commit (or the follow-up if cleanup was forgotten).
- Items can be added by anyone; new entries go to the bottom of their category so ordering stays stable.
