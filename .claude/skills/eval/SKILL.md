---
name: eval
description: Run a setup eval — launch a project, monitor the agent, record results
user_invocable: true
---

# Eval: Test Project Setup End-to-End

Run an automated eval that launches a project in BoomLooper, monitors the setup agent until services are healthy, auto-nudges when it stalls, and records results.

## Prerequisites

- BoomLooper must be running (start with `mix phx.server` or `overmind start -f Procfile.dev -D`)
- You must be in the **BoomLooper repo root**

## The `bin/op` Tool

All operator commands go through `bin/op`. This handles RPC, cookies, and node connections automatically.

```bash
bin/op connect Claude     # Connect as operator (green indicator in UI)
bin/op working "message"  # Set working status (yellow indicator)
bin/op danger "message"   # Set danger status (red indicator)
bin/op disconnect         # Disconnect (indicator disappears)
bin/op status             # Show current status
bin/op eval <path>        # Run eval on project
bin/op eval <path> --wipe # Run eval, wiping existing project first
bin/op projects           # List projects
bin/op agents             # List agents
```

## Running an Eval

### Quick Start

```bash
bin/op connect Claude
bin/op eval ~/Projects/some-project --wipe
bin/op disconnect
```

The eval:
1. Registers the project in BoomLooper
2. Spawns a setup agent
3. Monitors until services are healthy (or timeout)
4. Auto-nudges when the agent goes idle
5. Records results to `evals/<project_name>/runs/<timestamp>.md`

### Options

- `--wipe` — Remove existing project + containers first (fresh start). Use for repeatable evals.
- Default timeout is 15 minutes. Large projects with slow Docker builds may take longer.

## What Success Looks Like

- **Outcome: completed** — services healthy, HTTP responds
- **Low nudge count** (0-2, not 5)
- **Low tool calls** (under 100)
- **Services healthy** — workspace, dev, postgres, redis all running

## Common Failure Modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `stalled` after 5 nudges | Agent confused or services won't start | Check container logs, fix prompt |
| No COPY + bundle install in Dockerfile | Agent didn't follow recipe | Emphasize in `setup_guide.md` |
| App binds to localhost | Can't access from outside container | Add `--binding 0.0.0.0` to Procfile.dev |
| 50+ service_status calls | Agent polling in a loop | Check container logs for actual error |

## Where Results Live

```
evals/
├── <project_name>/
│   └── runs/
│       └── <timestamp>.md      # one file per eval run
```

Each run file contains:
- Outcome (completed/stalled/timeout/failed), duration, message count, tool calls
- Nudge count
- Service status at completion
- Tool usage breakdown
- Error messages if any

## How to Iterate

1. **Run a trial** — `bin/op eval /path --wipe`
2. **Observe** — Read the run file in `evals/<name>/runs/`
3. **Diagnose** — What went wrong? Prompt issue or code issue?
4. **Fix ONE thing** — Edit `priv/prompts/setup_guide.md` or fix BoomLooper code
5. **Restart** — `mix compile && overmind restart web` (or restart your server)
6. **Run again** — Compare to previous run

## After Each Experiment

Prompt changes require recompilation:

```bash
mix compile --force && overmind restart web
```

Or if running directly: restart the `mix phx.server` process.
