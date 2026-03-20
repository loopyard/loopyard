# Plan: Event Log

## Problem

Things break silently. CLI sessions die, containers crash, services restart — and there's no log in the UI showing what happened. The only evidence is in the terminal running `mix phx.server`, which the user isn't watching.

## Solution

An append-only event log visible in the UI. Every lifecycle event gets logged with a timestamp and source. The log is viewable per-branch (all events for that branch's agents, services, and containers).

### Events to capture

- Agent CLI session died (with reason)
- Agent CLI session auto-restarted
- Container started / stopped / crashed (with exit info)
- Service started / stopped
- Docker build started / completed / failed
- Branch started / stopped
- Tool errors (Docker commands that failed)

### Implementation

Simple ETS table per branch. Each event is a map:
```elixir
%{
  timestamp: DateTime.utc_now(),
  source: "agent:Setup" | "service:dev" | "docker" | "branch",
  level: :info | :warning | :error,
  message: "CLI session died: {:normal, ...}"
}
```

A `BoomLooper.EventLog` module with `append(branch_id, event)` and `list(branch_id)`.

### UI

A "Log" tab or section in the branch view that shows recent events. Always visible — not hidden behind a click. Like a mini terminal showing system activity.

Or: a notification dot on the branch/agent when errors occur, with a flyout showing recent events.

### Not in scope
- Persistence across server restarts
- Log rotation (just cap at 500 events)
- Structured querying
