# Boom Looper — Multi-Player Claude Code Runner

A Phoenix LiveView app that lets a team share and interact with Claude Code agents in real-time through a chat interface.

**This is a multiplayer app.** Multiple people watch and interact with agents simultaneously from laptops, iPads, iPhones, etc. All UI state that matters must be server-driven (assigns, PubSub) — never rely on client-side state like `<details>` open/closed, JS toggles, or localStorage for anything that should be consistent across viewers. If you can't sync it, just show it.

## What it does

- Left sidebar: list of running Claude agents with status indicators
- Right panel: chat interface with message bubbles, tool call cards, streaming responses
- Any connected browser can send messages to any agent — responses broadcast to all viewers
- Agents auto-name themselves, names are editable inline
- URL-based routing: `/chat/:id` — bookmarkable, survives refresh
- Responsive: works on phones, tablets, and desktops

## Architecture

### Key files

- `lib/boom_looper/chat_agent.ex` — GenServer wrapping a `ClaudeCode` SDK session. Streams structured messages (text, tool use, errors) to viewers via PubSub.
- `lib/boom_looper/chat_agent_supervisor.ex` — DynamicSupervisor for chat agent processes
- `lib/boom_looper_web/live/chat_live.ex` — LiveView with chat UI. Handles agent CRUD, message send/receive, PubSub subscriptions, URL routing.
- `lib/boom_looper_web/plugs/basic_auth.ex` — Optional HTTP Basic Auth (enabled via env vars)
- `assets/js/app.js` — Minimal: ScrollBottom hook (auto-scroll messages), ChatForm hook (clear input after send)

### How it works

Each agent is a GenServer that owns a `ClaudeCode` SDK session. The SDK spawns `claude` CLI as a subprocess and communicates via NDJSON (newline-delimited JSON) over stdin/stdout. When a user sends a message, the agent streams the response and broadcasts each event via PubSub. The LiveView subscribes to the agent's topic and renders messages as they arrive.

```
Browser → LiveView → ChatAgent GenServer → ClaudeCode SDK → claude CLI subprocess
                  ↑                     ↓
                  └── PubSub broadcast ←┘
```

Permissions are skipped (`dangerously_skip_permissions: true`) because the security model is container isolation, not per-tool approval.

### Container model

All agents run inside Docker containers. Claude CLI runs on the host but interacts with containers exclusively through MCP container tools (`exec`, `rebuild`, `start_service`, etc.). The only variable is the workspace volume strategy:

- **Bind mount** (default) — host directory mounted at `/workspace`. Edits inside the container appear on the host immediately. Used for working on existing projects.
- **Named volume** — isolated `/workspace` volume. Agent starts with an empty workspace. Used for sandboxed/greenfield work (not yet exposed in UI).

The Dockerfile controls what's pre-installed in the container (e.g., `elixir:1.18` base for Elixir projects, `ubuntu:22.04` for general use). Cache volume (`/root/.cache`) always persists across rebuilds.

### Agent lifecycle & UI states

Agents go through lifecycle states that the UI must reflect:

- **Booting** — Agent spawn is async. The LiveView navigates to `/chat/:id` immediately and shows a spinner/status screen while the GenServer initializes (Docker image build, container creation, SDK session start). The `chat_agent_started` PubSub event transitions the UI to the running state.
- **Idle** — Green dot. Agent is ready, waiting for input.
- **Thinking** — Amber pulsing dot. Agent is processing a message.
- **Stopped** — Grey dot. Agent was stopped.

When adding new agent types or initialization steps, always ensure the UI shows progress. Never block the LiveView process on slow operations — spawn async and let PubSub drive state transitions.

## Configuration (12-Factor)

All runtime config from environment variables. `.env` files loaded automatically in dev/test via `dotenvy`.

```bash
cp .env.example .env
```

| Variable | Required | Default | Description |
|---|---|---|---|
| `SECRET_KEY_BASE` | prod only | — | `mix phx.gen.secret` |
| `PHX_HOST` | prod only | `example.com` | Production hostname |
| `PORT` | no | `4000` | HTTP port |
| `HIVE_AUTH_PASSWORD` | no | — | Enable HTTP Basic Auth |
| `HIVE_AUTH_USERNAME` | no | *(any)* | Require specific username |

## Running

```bash
export MIX_HOME="$PWD/.mix_home"
export HEX_HOME="$PWD/.hex_home"

mix local.hex --force
mix deps.get
mix assets.setup
mix assets.build

mix phx.server
# http://localhost:4000
```

## Testing

**Test coverage is critical.** We rely on tests to iterate fast with high confidence. Every change must be backed by tests. If you're unsure whether something works, write a test first.

### Running tests

```bash
mix test                    # Run all tests
mix test --trace            # Verbose output
```

### Test philosophy

- **Every new feature must have tests.** No exceptions. If you add a module, add a test file.
- **Every bug fix starts with a failing test.** Reproduce it in a test, then fix it.
- **Test behavior, not implementation.** Test what functions return and what side effects they produce.
- **Tests must be fast.** No `Process.sleep` hacks. Use PubSub, `assert_receive`, or poll-with-timeout patterns to wait for async events. If you must sleep, you need a very good reason and a comment explaining why. No external API calls. Use the ClaudeCode test stubs for SDK interactions.
- **LiveView tests cover user flows.** Mount, click, submit, assert. Use `Phoenix.LiveViewTest`.
- **Plans require tests.** When implementing work from `./plans/*`, the plan is not done until there are comprehensive tests that verify the behavior end-to-end and catch regressions. If a plan involves Docker, browser, or other external deps, write tests that exercise the real thing (tagged for conditional execution) AND unit tests that run without the dependency.

### Test tags

- Default: all tests run with `mix test`
- `@tag :docker` — requires Docker daemon. Excluded by default, run with `mix test --include docker`
- Always write both: unit tests (no deps, always run) AND integration tests (tagged, exercise the real system)

### Test file organization

```
test/
  test_helper.exs
  support/
    conn_case.ex
  hive/
    chat_agent_test.exs      # ChatAgent GenServer tests
  hive_web/
    plugs/
      basic_auth_test.exs    # Auth plug tests
    live/
      chat_live_test.exs     # LiveView rendering, events, navigation
```

## Code style

### Composition over conditionals

Use functional composition — small, focused components and functions. Do NOT:
- Jam everything into mega-views with `if/else` scattered throughout templates
- Use `:if` guards to switch between completely different UIs in one template
- Build god-modules that handle every case

Instead:
- Extract LiveView function components for distinct UI sections
- Use separate LiveView modules when views have different data needs
- Compose with `render_slot`, function components, and pattern matching
- Each component should do one thing

```elixir
# Bad — one template with conditionals everywhere
<div :if={@tab == :chat}>... 100 lines ...</div>
<div :if={@tab == :ops && @has_container}>... 80 lines ...</div>
<div :if={@tab == :ops && !@has_container}>... 60 lines ...</div>

# Good — composed components
<.chat_panel :if={@tab == :chat} messages={@messages} ... />
<.ops_panel :if={@tab == :ops} agent={@selected_agent} has_container={@ops_has_container} ... />
```

This applies to tools and GenServers too — compose behaviours, don't branch.

### One concept, one code path

Don't create parallel implementations for things that are really the same thing with different config. If two "types" share 90% of their logic, they're one type with an option — not two types.

```elixir
# Bad — two types with parallel code paths
if is_root do
  create_root(id, dir)
else
  create(id)
end

# Good — one function, options control behavior
Docker.create(id, bind_mount: dir)
Docker.create(id)  # named volume by default
```

When you find yourself adding `root` / `docker` / `type` branches everywhere, stop and ask: "what's the actual parameter that differs?" Usually it's one thing (a path, a flag, a config value). Make that the option and delete the branching.

### Tests skip external dependencies by default

`ChatAgent` no longer creates Docker containers on init — the workspace container is managed by `ServiceManager`. Only tests tagged `@tag :docker` should actually create containers. This keeps `mix test` fast and Docker-free.

## Git workflow

- **Atomic commits.** Each commit is a self-contained, working change.
- Run `mix test` before committing. All tests must pass.
- Write descriptive commit messages that explain *why*, not just *what*.

## Stack

- Elixir 1.19 / OTP 28
- Phoenix 1.7 / LiveView 1.1
- Claude Code SDK (`claude_code` hex package) for structured agent communication
- Tailwind CSS (dark mode via `prefers-color-scheme`)
- Bandit (HTTP server)
- No database (all state in-memory in GenServer processes)

## Known issues / TODOs

- No persistence — all agents lost on server restart
- Agent message history grows unbounded in memory
- No markdown rendering in chat bubbles (messages are plain text)
- Workspaces — planned feature to let agents target different host directories (or named volumes for sandboxed work)
