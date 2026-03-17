---
title: Loops — The Core Abstraction
status: thinking
depends_on: [02-docker-integration]
---

# Loops

Everything in Hive is a loop. A loop is a long-running thing that:
1. Has state
2. Accepts input
3. Produces output
4. Can be observed (logs, status)
5. Can be controlled (start, stop, restart, nudge)

## Examples

| Loop | What it does | Input | Output |
|------|-------------|-------|--------|
| Agent | Claude thinking | Messages from humans/agents | Tool calls, responses |
| Dev REPL | Commands building the app | Shell commands | stdout/stderr |
| Web server | Serves pages | HTTP requests | HTTP responses, logs |
| Database | Stores data | SQL queries | Query results, logs |
| Dockerfile improver | Keeps env healthy | Build failures | Updated Dockerfile, rebuild |
| Browser | Tests the app | Navigation commands | Screenshots, DOM |

## The Pattern

Every loop is the same shape:
- **A process** that keeps running
- **A tool boundary** — what the agent can do to it (the control surface)
- **An operator** — could be a human watching, or another agent managing it
- **Observable state** — logs, health, metrics

Right now we model these as:
- Agent → GenServer (ChatAgent)
- Container → Docker tools
- Services → start_service/stop_service/logs tools

But they're all the same thing. A GenServer (or process) that runs, accepts messages, emits events. The tool boundary is just the public API. The UI is just observing the events.

## What if Loop was the abstraction?

```elixir
defmodule Hive.Loop do
  # A loop has:
  # - An ID
  # - A type (:agent, :server, :database, :repl, :browser)
  # - State (running, stopped, error)
  # - A parent (which loop spawned it)
  # - Input channel (how to send it stuff)
  # - Output channel (PubSub topic for events/logs)
  # - Tool boundary (what operations are available)
end
```

An agent is a loop that spawns other loops:
- Agent creates a REPL loop (the container)
- Agent creates a server loop (web server inside container)
- Agent creates a database loop (postgres inside container)
- If something breaks, agent (or a helper loop) fixes it

## The Dockerfile improver

This is interesting — it's a loop that watches for failures and improves the environment:
1. Agent tries to install something → fails
2. Dockerfile loop catches the failure
3. Edits Dockerfile, rebuilds
4. Retries the original command

This could be a separate agent, or it could be a hook on the container that auto-fixes env issues. Either way, it's a loop.

## UI implications

If everything is a loop:
- Sidebar shows ALL loops, nested under their parent
- Each loop has the same basic UI: status, logs, controls
- Agent loop adds chat UI
- Server loop adds port/URL
- Browser loop adds screenshot

The tabs we just built (Chat / Ops) become:
- Chat = the agent loop's interactive input
- Ops = the agent loop's children (its spawned loops)

## Open questions

- Is Loop a GenServer? A behaviour? A protocol?
- How do loops discover each other?
- Should loops have a supervision tree? (Loop crashes → parent restarts it)
- How does this relate to OTP supervisors? (It IS OTP, just named differently)
- Is this just OTP with a UI? (Yes, and that's the point)
