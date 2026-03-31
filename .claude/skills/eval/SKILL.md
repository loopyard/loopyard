---
name: eval
description: Run a setup eval — launch a project, monitor the agent, record results
user_invocable: true
---

# Eval: Test Project Setup End-to-End

Run an automated eval that launches a project in BoomLooper, monitors the setup agent until services are healthy, auto-nudges when it stalls, and records results.

## Prerequisites

- BoomLooper must be running (`mix boom.server`)
- You must be in the BoomLooper repo root

## Running an Eval

Jack into the running server and call EvalRunner directly:

```bash
# Fresh eval (wipes existing project + containers)
mix boom.rpc 'BoomLooper.EvalRunner.run("/Users/you/Projects/some-app", clean: true, timeout: 900_000)'

# Keep existing state
mix boom.rpc 'BoomLooper.EvalRunner.run("/Users/you/Projects/some-app", timeout: 900_000)'
```

## Monitoring

While the eval runs, jack in and check on things:

```bash
mix boom.rpc 'BoomLooper.ChatAgent.list_agents()'
mix boom.rpc 'BoomLooper.Workspace.ServiceManager.service_status("/Users/you/Projects/some-app")'
mix boom.rpc 'BoomLooper.Docker.docker(["ps", "--format", "table {{.Names}}\t{{.Status}}"])'
mix boom.rpc 'BoomLooper.ChatAgent.stop_agent("agent_id")'
```

Any Elixir expression works. The UI shows a yellow indicator while you're jacked in.

## What Success Looks Like

- **Outcome: completed** — services healthy, HTTP responds
- **Low nudge count** (0-2)
- **Low tool calls** (under 100)
- **Services visible in sidebar** — workspace, dev, postgres, etc.

## Results

Each eval writes to `evals/<project_name>/runs/<timestamp>.md` with outcome, duration, tool calls, errors, and service status.

## Iterating

1. Run eval
2. Read results in `evals/<name>/runs/`
3. Diagnose — jack in with `mix boom.rpc` to inspect live state
4. Fix prompt or code
5. Hot-reload: `mix boom.rpc 'IEx.Helpers.recompile()'`
6. Run again, compare
