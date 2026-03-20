# Plan: Service Console

## Summary

Add an interactive terminal console for each service container. Click "Console" on any service (postgres, dev, redis) and get a shell inside that container — from any device (phone, tablet, desktop).

## Two Phases

### Phase 1: Command Runner (Quick)

A text input on the service log view. Type a command, hit enter, see output. Not interactive (no readline, no cursor), but covers 80% of use cases:

```
postgres > SELECT count(*) FROM users;
 count
-------
    42
(1 row)

postgres > \dt
         List of relations
...
```

**Implementation:**
- Add a command input to the service log view header
- New LiveView event `run_service_command` that calls `Docker.exec_in(container, command)`
- Append command + output to a log list in assigns
- Scroll to bottom on each command
- Works on all devices — just a text input and pre-formatted output

**Routes:** No new routes needed. Uses existing `/p/:project_id/b/:branch_id/service/:name` page.

### Phase 2: Full Terminal (Later)

A real terminal emulator in the browser using xterm.js + WebSocket + PTY.

**Why it's harder:**
- Need xterm.js (npm package) bundled into assets
- Need a WebSocket channel (not LiveView) for raw byte streaming
- Need to spawn a PTY inside the Docker container (`docker exec -it` equivalent)
- PTY management: resize events, stdin/stdout piping, cleanup on disconnect
- Mobile keyboard handling (xterm.js has issues on iOS)

**Architecture:**
```
Browser (xterm.js) ← WebSocket → Phoenix Channel → Port (docker exec -it) → Container Shell
```

**New modules:**
- `BoomLooperWeb.TerminalChannel` — Phoenix Channel for bidirectional byte streaming
- `BoomLooper.Terminal` — GenServer wrapping a Port/PTY to `docker exec -it`
- `assets/js/terminal.js` — xterm.js integration

**Routes:**
- `/p/:project_id/b/:branch_id/service/:name/console` — full terminal view
- Or embedded in the service log view as a tab

**Mobile considerations:**
- xterm.js works on mobile but keyboard handling is tricky
- Consider a hybrid: show the Phase 1 command input on mobile, full terminal on desktop
- Or use xterm.js with `mobile: true` config and a visible keyboard toggle

## Recommendation

Ship Phase 1 now — it works everywhere, no dependencies, covers most debugging needs. Plan Phase 2 when interactive sessions become a bottleneck (e.g., running `psql` interactively, using vim inside a container).
