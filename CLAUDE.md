# Hive — Multi-Player Claude Code Runner

A Phoenix LiveView app that lets a team share and interact with Claude Code sessions in real-time through the browser.

## What it does

- Left sidebar: list of running Claude Code agents (name, working dir, status, PID, viewer count)
- Right panel: xterm.js terminal rendering the agent's PTY output
- Any connected browser can type into any agent — keystrokes go to stdin, output broadcasts to all viewers
- Kill button sends SIGKILL to the OS process
- Connection indicators show how many browsers are viewing each agent
- Quick-start templates for common agent configurations
- Optional HTTP Basic Auth via `HIVE_AUTH_PASSWORD` env var

## Architecture

### Key files

- `lib/hive/agent.ex` — GenServer wrapping a Claude Code process. Uses `Hive.PTY` for cross-platform PTY allocation. Broadcasts raw stdio over PubSub. Uses `Hive.RingBuffer` to cap output memory.
- `lib/hive/ring_buffer.ex` — Capped binary ring buffer (256KB default) to prevent unbounded memory growth from agent output.
- `lib/hive/pty.ex` — Cross-platform PTY wrapper. Handles macOS vs Linux `script` command syntax differences.
- `lib/hive/agent_supervisor.ex` — DynamicSupervisor for agent processes
- `lib/hive_web/live/dashboard_live.ex` — Single LiveView with split-panel layout, extracted into function components. Subscribes to PubSub topics per-agent. Pushes terminal data to client via `push_event`.
- `lib/hive_web/presence.ex` — Phoenix Presence for tracking connected viewers per agent.
- `lib/hive_web/plugs/basic_auth.ex` — Optional HTTP Basic Auth plug (enabled via env vars).
- `assets/js/app.js` — xterm.js Terminal hook with FitAddon. Sends raw keystrokes back via `pushEvent("terminal_input", ...)`.

### How the PTY works

Claude Code requires a TTY for interactive mode. Erlang Ports use pipes, not PTYs. We wrap the `claude` command in the OS-appropriate `script` command to allocate a PTY.

```
Port -> script (PTY) -> claude (interactive)
```

The PTY size defaults to 120 cols x 40 rows (set via env vars COLUMNS/LINES). The `Hive.PTY` module handles platform differences:
- macOS: `script -q /dev/null <cmd>`
- Linux: `script -qc <cmd> /dev/null`

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

## Configuration (12-Factor)

All runtime configuration is driven by environment variables (per [12-factor app](https://12factor.net/) principles). In dev/test, variables are loaded from `.env` files automatically via `dotenvy`.

```bash
# Copy the example env file and customize:
cp .env.example .env
```

### Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `SECRET_KEY_BASE` | prod only | — | Phoenix secret (generate with `mix phx.gen.secret`) |
| `PHX_HOST` | prod only | `example.com` | Production hostname |
| `PORT` | no | `4000` | HTTP port |
| `HIVE_AUTH_PASSWORD` | no | — | Enable HTTP Basic Auth with this password |
| `HIVE_AUTH_USERNAME` | no | *(any)* | Require specific username (with `HIVE_AUTH_PASSWORD`) |

### .env files

- `.env` — loaded in dev and test (git-ignored, never commit)
- `.env.dev` / `.env.test` — environment-specific overrides
- `.env.example` — checked in, documents all available variables

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

## Testing

We aim for comprehensive test coverage to enable confident automated development. Tests should be the primary way to verify changes work correctly.

### Running tests

```bash
mix test                    # Run all tests
mix test --trace            # Run with verbose output
mix test test/hive/         # Run only unit tests
mix test test/hive_web/     # Run only web tests
```

### Test philosophy

- **Every new feature must have tests.** If you're adding a module, add a corresponding test file.
- **Test behavior, not implementation.** Test what functions return and what side effects they produce, not internal state.
- **Unit tests for core logic** — `RingBuffer`, `PTY`, `Agent` validation, auth plug, etc. These should be fast and `async: true`.
- **LiveView tests for UI behavior** — Use `Phoenix.LiveViewTest` to verify rendering, events, and navigation.
- **Integration tests for agent lifecycle** — Test agent start/stop/kill flows end-to-end when possible.
- **Use `test/support/` for shared helpers** — `ConnCase` for web tests, add more as needed.

### Test file organization

```
test/
  test_helper.exs
  support/
    conn_case.ex           # Shared setup for web tests
  hive/
    ring_buffer_test.exs   # Unit tests for RingBuffer
    pty_test.exs           # Unit tests for PTY module
    agent_test.exs         # Agent validation and lifecycle tests
  hive_web/
    plugs/
      basic_auth_test.exs  # Auth plug tests
    live/
      dashboard_live_test.exs  # LiveView rendering and event tests
```

### When making changes

1. Run `mix test` before and after changes to ensure nothing breaks
2. Add tests for any new public functions or event handlers
3. If a bug is found, write a failing test first, then fix it
4. Keep tests fast — avoid unnecessary sleeps or waits

## Git workflow

- **Make commits atomic.** Each commit should be a self-contained, working change. Don't mix unrelated features in one commit.
- Run `mix test` before committing. All tests must pass.
- Write descriptive commit messages that explain *why*, not just *what*.

## Stack

- Elixir 1.19 / OTP 28
- Phoenix 1.7 / LiveView 1.1
- Tailwind CSS (with dark mode via `prefers-color-scheme`)
- xterm.js (terminal rendering in browser)
- Bandit (HTTP server)
- No database (all state is in-memory in GenServer processes)

## Multi-device support

The UI is responsive and works across desktop, tablet, and phone:

- **Desktop (md+)**: Split-panel layout with persistent sidebar
- **Mobile (<md)**: Full-screen terminal with slide-out sidebar overlay
- **Terminal auto-fits** to container via xterm.js FitAddon + ResizeObserver
- **Touch support**: Tap to focus terminal, touch-scroll works naturally
- **Connection status**: Banner appears on WebSocket disconnect, auto-hides on reconnect
- **Safe area insets**: Supports notched devices (iPhone etc) via `viewport-fit=cover`
- **Orientation change**: Terminal re-fits on device rotation
- **PWA-ready**: `apple-mobile-web-app-capable` meta tag for home screen launch

## Known issues / TODOs

- Terminal auto-fits to viewport but PTY-level resize (SIGWINCH) not yet wired — all viewers see the same PTY dimensions regardless of screen size
- Agent output capped at 256KB via ring buffer — older output is dropped
- `kill -9` uses process tree cleanup (pgrep + kill children) but may still miss deeply nested processes
- No persistence — all agents lost on server restart
- Cloudflare quick tunnels work for sharing (`cloudflared tunnel --url http://localhost:4000`) but are ephemeral
- Mobile keyboard may obscure terminal on some devices — could be improved with visual viewport API
