# Plan: Service Console

## Summary

Interactive terminal console for any service container. Click "Console" on postgres, dev, redis — get a shared shell session. Multiplayer: everyone watching sees the same terminal. Works on phones, tablets, desktops.

## Architecture

```
Browser (xterm.js) ← WebSocket → Phoenix Channel → Port (docker exec -it) → Container Shell
```

### Key Modules

- `BoomLooper.Terminal` — GenServer wrapping a Port to `docker exec -it`. One per active console session. Broadcasts output via PubSub.
- `BoomLooperWeb.TerminalChannel` — Phoenix Channel for bidirectional byte streaming between browser and Terminal GenServer.
- `assets/js/terminal.js` — xterm.js integration, connects to the channel.

### Terminal GenServer

```elixir
defmodule BoomLooper.Terminal do
  use GenServer

  # State: port, container_name, subscribers
  # Start: opens Port to `docker exec -it <container> /bin/sh`
  # Input: receives bytes from channel, writes to port stdin
  # Output: reads from port stdout, broadcasts to PubSub topic
  # Resize: sends SIGWINCH via `docker exec` resize API
  # Cleanup: Port.close on terminate
end
```

Shared session: one Terminal GenServer per container. Multiple Channel subscribers see the same output. Anyone can type — like a shared Google Doc but for a terminal.

### Channel

```elixir
defmodule BoomLooperWeb.TerminalChannel do
  use Phoenix.Channel

  # join "terminal:<container_name>" — subscribe to Terminal output
  # handle_in "input" — forward keystrokes to Terminal GenServer
  # handle_in "resize" — forward terminal size changes
  # handle_info {:terminal_output, data} — push to browser
end
```

### Frontend

xterm.js handles rendering. The JS hook:
1. Creates xterm.Terminal instance
2. Joins the Phoenix Channel for this container
3. Pipes xterm onData → channel "input" events
4. Pipes channel "output" events → xterm.write()
5. Sends resize events when terminal dimensions change

### UI Integration

Add a "Console" button/tab on each service in the sidebar or service log view. Clicking it opens the terminal inline or in a new route:

```
/p/:project_id/b/:branch_id/service/:name/console
```

The terminal fills the main panel. Service logs and console are tabs.

### Multiplayer

- One Terminal GenServer per container — shared session
- All connected browsers see the same shell
- Anyone can type — input from all clients goes to the same stdin
- New joiners get a screen buffer replay (xterm.js serialization) so they see existing content
- PubSub broadcasts ensure all LiveView/Channel subscribers stay in sync

### Mobile

- xterm.js works on mobile browsers
- iOS keyboard works but needs `inputMode: "text"` on the xterm container
- Consider showing a visible "tap to type" overlay on mobile since there's no physical keyboard focus

### Dependencies

- `xterm` npm package (+ `@xterm/addon-fit` for auto-resize)
- No server-side dependencies beyond what we have (Port, GenServer, Channel)

## Implementation Order

1. Add xterm.js to assets (`npm install xterm @xterm/addon-fit`)
2. Create `BoomLooper.Terminal` GenServer
3. Create `BoomLooperWeb.TerminalChannel`
4. Create `assets/js/terminal.js` hook
5. Add console route and UI
6. Add multiplayer replay (serialize xterm buffer for late joiners)
7. Mobile polish

## Not in scope

- Multiple independent sessions per container (one shared session is fine)
- Terminal persistence across server restarts (session dies with server)
- Recording/playback of terminal sessions
