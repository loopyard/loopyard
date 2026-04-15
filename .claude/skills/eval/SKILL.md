---
name: eval
description: Run a setup eval — launch a project, monitor the agent, record results
user_invocable: true
---

# Eval: Test Project Setup End-to-End

Run an automated eval that launches a project in BoomLooper and monitors the setup agent until services are healthy.

**Critical principle: zero nudges.** An eval only truly passes if the agent completes setup with NO human intervention. If nudges are needed, that's a system failure to fix — not a successful eval.

Evals test the full Docker-based setup flow: source adapter seeds the volume, agent writes Dockerfile and docker-compose.yml, containers build and start, agent installs deps and verifies HTTP from the host. No host filesystem shortcuts.

## Prerequisites

- BoomLooper must be running (`mix boom.server`)
- You must be in the BoomLooper repo root

## Eval Projects

Eval projects live in `./evals/<name>/project/`. The `project/` subdirectory is gitignored — clone or copy test repos there.

Example structure:
```
evals/
  rails-app/
    project/      # <- the actual Rails repo (gitignored)
    runs/         # <- eval results (tracked)
      2024-01-15T10-30-00.md
```

## Running an Eval

Jack into the running server and call EvalRunner directly:

```bash
mix boom.rpc 'BoomLooper.EvalRunner.run("evals/rails-app/project")'
```

Evals run asynchronously — `run/2` returns immediately with `{:ok, pid}`.

## Monitoring

```bash
# Check all running/completed evals
mix boom.rpc 'BoomLooper.EvalRunner.status()'

# Deeper inspection
mix boom.rpc 'BoomLooper.ChatAgent.list_agents()'
mix boom.rpc 'BoomLooper.Workspace.ServiceManager.service_status("evals/rails-app/project")'
mix boom.rpc 'BoomLooper.Docker.docker(["ps", "--format", "table {{.Names}}\t{{.Status}}"])'
mix boom.rpc 'BoomLooper.ChatAgent.stop_agent("agent_id")'
```

Any Elixir expression works. The UI shows a yellow indicator while you're jacked in.

## What Success Looks Like

- **Outcome: success** — web service returns HTTP 2xx
- **Zero nudges** — agent completed entirely autonomously
- **Reasonable tool calls** — varies by project complexity
- **Services visible in sidebar** — workspace, dev, postgres, etc.

Other outcomes: `failed` (agent crashed/stopped), `stalled` (went idle before HTTP 200), `timeout` (deadline hit), `web_error` (HTTP response but non-2xx).

**If an eval needs nudges, that's a bug to fix:**
- Don't celebrate a "success with 2 nudges" — fix why it stalled
- The system should auto-continue on rebuild completion/failure messages
- Prompts should teach the agent to keep iterating until HTTP 200
- Add diverse eval projects (Python, Node, Go) to catch overfitting

## Results

Results are written to `evals/<name>/runs/<timestamp>.md` (sibling to `project/`) with outcome, duration, tool calls, errors, and service status.

## Iterating

1. Run eval
2. Read results in `evals/<name>/runs/`
3. Diagnose — jack in with `mix boom.rpc` to inspect live state
4. Fix prompt or code
5. Hot-reload: `mix boom.rpc 'BoomLooper.HotReload.reload()'`

   **Don't use `IEx.Helpers.recompile()` alone.** If `mix compile` already ran in a separate shell (VS Code, editor save, CI), `recompile()` returns `:noop` and the BEAM keeps serving the OLD bytecode — your fix won't take effect and you'll chase a ghost. `BoomLooper.HotReload.reload/0` re-purges and re-loads every `BoomLooper.*` / `BoomLooperWeb.*` module whose `.beam` file was written in the last minute, which covers the common mix-compile-then-reload case. Verify the reload worked by calling the fixed function and inspecting its output before re-running an eval.

6. Run again, compare

## Avoiding Overfitting

**Don't optimize for your current evals.** If all evals are Ruby/Rails, you might accidentally hard-code Ruby assumptions.

Signs of overfitting:
- Hard-coded paths like `/usr/local/bundle` (Ruby-specific)
- String matching for specific errors ("bundle install failed")
- Fixes that only work for the project you're debugging

How to prevent it:
- Keep core system code technology-agnostic
- Add evals for different stacks (Python/Django, Node/Express, Go, Rust)
- Prompts teach patterns with examples, not hard-coded commands
- Agent discovers the stack by reading the codebase, then adapts

When an eval fails, fix **prompts** or **tools** — not the system code with project-specific hacks.
