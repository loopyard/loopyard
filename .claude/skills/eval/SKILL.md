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

## Eval Directory Structure

Each eval lives in `evals/<name>/`:

```
evals/<name>/
  eval.md          # config (frontmatter: title, git_url) + description — tracked in git
  runs/            # timestamped result markdown files — tracked in git
  project/         # cloned project source — gitignored, machine-local
```

Example `eval.md` frontmatter:

```markdown
---
title: Maybe Finance
git_url: https://github.com/maybe-finance/maybe.git
---

Description of what this eval tests and what success looks like.
```

Configs and run results are committed so you can track eval performance over time across machines. Project clones are gitignored since they're large and machine-local.

## Running an Eval

Jack into the running server and call EvalRunner:

```bash
# By name (looks up git URL from evals/<name>/eval.md):
mix boom.rpc 'BoomLooper.EvalRunner.eval("maybe-finance")'

# By git URL directly:
mix boom.rpc 'BoomLooper.EvalRunner.run("https://github.com/maybe-finance/maybe.git")'

# List available evals:
mix boom.rpc 'BoomLooper.EvalRunner.list_evals()'
```

Every eval always starts fresh — tears down existing project, volumes, and containers first.

Evals run asynchronously — `eval/1` and `run/1` return immediately with `{:ok, pid}`.

## Monitoring

```bash
# Check all running/completed evals
mix boom.rpc 'BoomLooper.EvalRunner.status()'

# Deeper inspection
mix boom.rpc 'BoomLooper.ChatAgent.list_agents()'
mix boom.rpc 'BoomLooper.Docker.docker(["ps", "--format", "table {{.Names}}\t{{.Status}}"])'
mix boom.rpc 'BoomLooper.ChatAgent.stop_agent("agent_id")'
```

Any Elixir expression works. The UI shows a yellow indicator while you're jacked in.

## What Success Looks Like

- **Outcome: success** — web service returns HTTP 2xx
- **Low nudge count** (0-2)
- **Low tool calls** (under 100)
- **Services visible in sidebar** — workspace, dev, postgres, etc.

Other outcomes: `failed` (agent crashed/stopped), `stalled` (idle after max nudges, no HTTP response), `timeout` (deadline hit), `web_error` (HTTP response but non-2xx after max nudges).

The eval probes the web service via HTTP at each check. Error response bodies (4xx/5xx) are fed back to the agent as nudge messages so it can debug.

## Important: Don't Help the Setup Agent

The point of evals is to measure whether the setup agent can configure a project **on its own** using only its system prompt, MCP tools, and stack guides. Do NOT:

- Give the setup agent hints about what's wrong
- Manually fix the workspace config
- Exec into containers to run commands for it
- Modify the project's code to make setup easier

If the agent fails, the fix belongs in the **prompts** (`priv/prompts/setup_guide.md`, `priv/prompts/stacks/*.md`), the **MCP tools** (`lib/boom_looper/tools/workspace.ex`), or the **EvalRunner nudge logic** — not in hand-holding the agent through a specific project.

## Iterating

1. Run eval
2. Read results in `evals/<name>/runs/`
3. Diagnose — jack in with `mix boom.rpc` to inspect live state
4. Fix prompts, tools, or infrastructure code
5. Hot-reload: `mix boom.rpc 'IEx.Helpers.recompile()'`
6. Run again, compare
