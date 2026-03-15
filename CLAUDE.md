# Hive — Multi-Player Claude Code Runner

A Phoenix LiveView app that lets a team share and interact with Claude Code sessions in real-time through the browser.

## What it does

- Left sidebar: list of running Claude Code agents (name, working dir, status, PID)
- Right panel: xterm.js terminal rendering the agent's PTY output
- Any connected browser can type into any agent — keystrokes go to stdin, output broadcasts to all viewers
- Kill button sends SIGKILL to the OS process

## Architecture

### Key files

- `lib/hive/agent.ex` — GenServer wrapping a Claude Code process. Uses Erlang Port + macOS `script` command for PTY allocation. Broadcasts raw stdio over PubSub.
- `lib/hive/agent_supervisor.ex` — DynamicSupervisor for agent processes
- `lib/hive_web/live/dashboard_live.ex` — Single LiveView with split-panel layout. Subscribes to PubSub topics per-agent. Pushes terminal data to client via `push_event`.
- `assets/js/app.js` — xterm.js Terminal hook. Fixed 120x40 grid (must match PTY size in agent.ex). Sends raw keystrokes back via `pushEvent("terminal_input", ...)`.

### How the PTY works

Claude Code requires a TTY for interactive mode. Erlang Ports use pipes, not PTYs. We wrap the `claude` command in macOS `script -q /dev/null <cmd>` to allocate a PTY.

```
Port -> script (PTY) -> claude (interactive)
```

The PTY is fixed at 120 cols x 40 rows (set via env vars COLUMNS/LINES). The xterm.js client is locked to the same dimensions. This keeps all connected browsers in sync — no per-client resize.

### Things we tried that didn't work

- **`claude --verbose` (interactive mode via Port)**: No output — Claude needs a TTY, Ports use pipes
- **`claude --print --output-format stream-json --input-format stream-json`**: The `--input-format stream-json` protocol is undocumented/broken. Messages sent on stdin were ignored.
- **`claude --print --output-format stream-json --verbose`**: Works for one-shot prompts piped via stdin, but doesn't support ongoing conversation without `--resume`
- **Parsing JSON stream events**: Overengineered. Raw stdio via PTY is simpler and gives you the real Claude Code experience (ANSI colors, tool use rendering, etc.)

### What does work

```bash
# This is what each agent runs under the hood:
script -q /dev/null /path/to/claude
```

With env: `TERM=xterm-256color COLUMNS=120 LINES=40`

## Running

```bash
# ~/.mix has a permissions issue in some sandboxes, use local MIX_HOME:
export MIX_HOME="$PWD/.mix_home"
export HEX_HOME="$PWD/.hex_home"

# First time setup
mix local.hex --force
mix deps.get
mix assets.setup
mix assets.build

# Run
mix phx.server
# http://localhost:4000
```

## Stack

- Elixir 1.19 / OTP 28
- Phoenix 1.7 / LiveView 1.1
- Tailwind CSS (with dark mode via `prefers-color-scheme`)
- xterm.js (terminal rendering in browser)
- Bandit (HTTP server)
- No database (all state is in-memory in GenServer processes)

## Known issues / TODOs

- Terminal size is fixed at 120x40 — doesn't adapt to browser window (intentional for multiplayer sync, but could be improved with a "resize all clients" approach)
- The `script` PTY wrapper is macOS-specific (`script -q /dev/null cmd`). Linux `script` has different syntax (`script -qc cmd /dev/null`)
- Agent output buffer grows unbounded in memory — needs a ring buffer or cap
- No auth — anyone with the URL can see and type into any agent
- No persistence — all agents lost on server restart
- `kill -9` on the `script` PID may leave orphan `claude` processes
- Cloudflare quick tunnels work for sharing (`cloudflared tunnel --url http://localhost:4000`) but are ephemeral
