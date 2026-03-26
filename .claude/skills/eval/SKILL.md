---
name: eval
description: Run a setup eval — launch a project, monitor the agent, record results
user_invocable: true
---

# Eval: Test Project Setup End-to-End

Run an automated eval that launches a project in BoomLooper, monitors the setup agent through its checklist, auto-nudges when it stalls, and records results.

## How to Connect

BoomLooper runs as a named Erlang node. Connect via RPC:

```bash
# ALWAYS use this pattern — ~/.erlang.cookie has eperm on this machine
source .env 2>/dev/null
HOME=/tmp MIX_HOME="$PWD/.mix_home" HEX_HOME="$PWD/.hex_home" \
  elixir --sname eval1 --cookie "$(cat "$BOOMLOOPER_HOME/cookie")" -e '
  # your RPC call here
'
```

Each `--sname` must be unique per invocation (eval1, eval2, eval3...).

## Running an Eval

### Quick: Use EvalRunner (blocks until done)

```bash
HOME=/tmp MIX_HOME="$PWD/.mix_home" HEX_HOME="$PWD/.hex_home" \
  elixir --sname eval1 --cookie "$(cat cookie)" -e '
  result = :rpc.call(:"boom@macbook", BoomLooper.EvalRunner, :run, [
    "/path/to/project",
    [clean: true, timeout: 900_000]
  ])
  IO.inspect(result)
'
```

Options:
- `clean: true` — remove existing project first (fresh start)
- `timeout: 900_000` — 15 min default, increase for large projects
- `max_nudges: 5` — auto-nudge when agent goes idle before checklist complete

### Manual: Step by Step

Use this when you want to watch and intervene:

```bash
# 1. List agents
HOME=/tmp ... elixir --sname e1 --cookie "$(cat cookie)" -e '
  :rpc.call(:"boom@macbook", BoomLooper.ChatAgent, :list_agents, [])
  |> Enum.each(fn a ->
    IO.puts("#{a[:id]} | #{a[:name]} | #{a[:status]} | msgs=#{length(a[:messages] || [])}")
  end)
'

# 2. Check agent state
HOME=/tmp ... elixir --sname e2 --cookie "$(cat cookie)" -e '
  state = :rpc.call(:"boom@macbook", BoomLooper.ChatAgent, :get_state, ["AGENT_ID"])
  IO.inspect(state[:status], label: "status")
  IO.inspect(state[:tool_calls], label: "tool_calls")
  msgs = state[:messages] || []
  msgs |> Enum.slice(-5..-1) |> Enum.each(fn m ->
    IO.puts("--- #{m[:role]}:#{m[:tool]} ---")
    IO.puts(String.slice(to_string(m[:content] || ""), 0..300))
  end)
'

# 3. Nudge a stalled agent
HOME=/tmp ... elixir --sname e3 --cookie "$(cat cookie)" -e '
  :rpc.call(:"boom@macbook", BoomLooper.ChatAgent, :send_message, [
    "AGENT_ID", "Continue with the remaining checklist items."
  ])
'

# 4. Stop an agent
HOME=/tmp ... elixir --sname e4 --cookie "$(cat cookie)" -e '
  :rpc.call(:"boom@macbook", BoomLooper.ChatAgent, :stop_agent, ["AGENT_ID"])
'

# 5. Remove a project (clean slate)
HOME=/tmp ... elixir --sname e5 --cookie "$(cat cookie)" -e '
  :rpc.call(:"boom@macbook", BoomLooper.ProjectRegistry, :remove_project, ["PROJECT_ID"])
'
```

## What to Look For

A successful eval:
- **11/11 checklist items** checked
- **0 build failures** (`build_failed` role messages)
- **Low service_status polls** (2-5, not 50+)
- **Services healthy** — workspace, dev, postgres, redis all running
- **Ports set** on the dev process (shows in sidebar as clickable link)

Common failure modes:
- **Build loop** — `up_stream` not falling back to `docker-compose` standalone. Fixed in `compose.ex`.
- **service_status spam** — agent polling forever. Usually means services aren't starting. Check container logs.
- **No ports** — agent forgot to pass `ports` to `set_dev_command`. The setup guide now tells it to.
- **Architecture mismatch** — esbuild/sharp/etc. macOS binaries in Linux container. Fix: `npm rebuild` after rebuild.
- **Missing database** — agent needs to `exec` with `rails db:create` / `createdb`. Checklist now explicit about this.

## Recording Results

EvalRunner writes to `evals/<project_name>/<date>.md` automatically. Key metrics:
- outcome, duration, message count, tool calls, errors, nudges, checklist progress
- service status at completion
- tool usage breakdown

## Iterating on Prompts

The eval loop is: run eval → read result → fix prompt → recompile → restart app → run again.

Files to edit:
- `priv/prompts/setup_guide.md` — sent as the first message to setup agents
- `priv/checklists/setup.md` — the checklist template
- `lib/boom_looper/chat_agent.ex` — system prompt (keep under 2000 chars)

**Important:** `setup_guide.md` is compiled into `ChatAgent` as a module attribute (`@setup_guide`). The app must be restarted (or code-reloaded) to pick up changes.
