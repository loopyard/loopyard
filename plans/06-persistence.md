---
title: Persistence
status: planned
depends_on: []
---

# Persistence

All state is currently in-memory. Server restart = everything lost.

## What needs persisting

- Agent metadata (id, name, working_dir, created_at)
- Conversation history (messages)
- Session IDs (for Claude Code `--resume` support)
- Tool instance state

## Options

| Option | Pros | Cons |
|--------|------|------|
| SQLite (via Ecto + ecto_sqlite3) | Simple, no server, file-based | Single-writer |
| Postgres | Full-featured, concurrent | Extra dependency |
| Plain files (JSON) | Zero deps | No queries, manual serialization |

SQLite is probably right for a single-node app. Postgres if we ever go multi-node.

## Acceptance criteria

- [ ] Agents survive server restart
- [ ] Conversation history preserved
- [ ] Can resume a Claude session after restart (via session_id)
- [ ] UI loads agents from database on mount
