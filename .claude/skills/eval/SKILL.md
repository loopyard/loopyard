---
name: eval
description: Run a setup eval — launch a project, monitor the agent, record results
user_invocable: true
---

# Eval: Test Project Setup End-to-End

Run an automated eval that launches a project in BoomLooper, monitors the setup agent through its checklist, auto-nudges when it stalls, and records results.

## Prerequisites

- BoomLooper must be running (`overmind start` or `mix boom.server`)
- You must be in the **BoomLooper repo root** (all paths are relative to it)
- The `.env` file sets `BOOMLOOPER_HOME=$PWD` — the cookie lives at `$PWD/cookie`

## How to Connect via RPC

Every RPC call uses this exact prefix. Do not abbreviate it.

```bash
HOME=/tmp MIX_HOME="$PWD/.mix_home" HEX_HOME="$PWD/.hex_home" \
  elixir --sname d1 --cookie "$(cat cookie)" -e '
  # Elixir code here, calling :rpc.call(:"boom@HOSTNAME", ...)
'
```

**Rules:**
- `HOME=/tmp` is required — `~/.erlang.cookie` has eperm on this machine and Erlang won't start distribution without it.
- `--sname` must be unique per invocation. Use d1, d2, d3... or eval1, eval2... Increment every time.
- The node name is `:"boom@HOSTNAME"` where HOSTNAME is `$(hostname -s)`. On this machine it's `macbook`, so `:"boom@macbook"`. On another machine, run `hostname -s` first.
- The cookie is at `$PWD/cookie` (repo root). This is NOT `~/.erlang.cookie`.

**If you get `:pang` or `:nodedown`:**
- `:nodedown` with correct cookie = app isn't running. Start it.
- `:pang` = cookie mismatch. The app regenerates the cookie on startup. If you restarted the app, re-read the cookie file — it changed.
- Run `epmd -names` to verify the `boom` node is registered.

## Running an Eval

### Automated: EvalRunner

Blocks until the agent completes the checklist or times out. Auto-nudges when the agent hits max_turns and goes idle.

```bash
HOME=/tmp MIX_HOME="$PWD/.mix_home" HEX_HOME="$PWD/.hex_home" \
  elixir --sname eval1 --cookie "$(cat cookie)" -e '
  result = :rpc.call(:"boom@macbook", BoomLooper.EvalRunner, :run, [
    "/absolute/path/to/project",
    [clean: true, timeout: 900_000]
  ])
  IO.inspect(result)
'
```

Options:
- `clean: true` — remove existing project + containers first (fresh start). Always use this for repeatable evals.
- `timeout: 900_000` — 15 minutes default. Large projects with slow Docker builds may need more.
- `max_nudges: 5` — how many times to auto-nudge when agent goes idle before checklist is complete. The agent hits max_turns (50) and stops; the runner sends "Continue with the remaining checklist items." and the agent keeps going.

Results are written to `evals/<project_name>/<timestamp>.md` in the repo root.

### Manual: Step by Step

Use this when you want to watch and intervene. Remember: every call needs the full prefix and a unique `--sname`.

**List agents:**
```bash
HOME=/tmp MIX_HOME="$PWD/.mix_home" HEX_HOME="$PWD/.hex_home" \
  elixir --sname d1 --cookie "$(cat cookie)" -e '
  :rpc.call(:"boom@macbook", BoomLooper.ChatAgent, :list_agents, [])
  |> Enum.each(fn a ->
    IO.puts("#{a[:id]} | #{a[:name]} | #{a[:status]} | msgs=#{length(a[:messages] || [])} | tools=#{a[:tool_calls] || 0}")
  end)
'
```

**Check agent state (last 5 messages):**
```bash
HOME=/tmp MIX_HOME="$PWD/.mix_home" HEX_HOME="$PWD/.hex_home" \
  elixir --sname d2 --cookie "$(cat cookie)" -e '
  state = :rpc.call(:"boom@macbook", BoomLooper.ChatAgent, :get_state, ["AGENT_ID"])
  IO.inspect(state[:status], label: "status")
  IO.inspect(state[:tool_calls], label: "tool_calls")
  IO.inspect(length(state[:messages] || []), label: "messages")
  msgs = state[:messages] || []
  msgs |> Enum.slice(-5..-1) |> Enum.each(fn m ->
    role = m[:role]
    tool = m[:tool]
    label = if tool, do: "#{role}:#{tool}", else: "#{role}"
    IO.puts("--- #{label} ---")
    IO.puts(String.slice(to_string(m[:content] || ""), 0..300))
  end)
'
```

**Nudge a stalled agent:**
```bash
HOME=/tmp MIX_HOME="$PWD/.mix_home" HEX_HOME="$PWD/.hex_home" \
  elixir --sname d3 --cookie "$(cat cookie)" -e '
  :rpc.call(:"boom@macbook", BoomLooper.ChatAgent, :send_message, [
    "AGENT_ID", "Continue with the remaining checklist items."
  ])
'
```

**Stop an agent:**
```bash
HOME=/tmp MIX_HOME="$PWD/.mix_home" HEX_HOME="$PWD/.hex_home" \
  elixir --sname d4 --cookie "$(cat cookie)" -e '
  :rpc.call(:"boom@macbook", BoomLooper.ChatAgent, :stop_agent, ["AGENT_ID"])
'
```

**Remove a project (clean slate for re-eval):**
```bash
HOME=/tmp MIX_HOME="$PWD/.mix_home" HEX_HOME="$PWD/.hex_home" \
  elixir --sname d5 --cookie "$(cat cookie)" -e '
  :rpc.call(:"boom@macbook", BoomLooper.ProjectRegistry, :remove_project, ["PROJECT_ID"])
'
```

## What Success Looks Like

- **11/11 checklist items** checked
- **0 build failures** (no `build_failed` role messages)
- **Low service_status polls** (2-5, not 50+)
- **Services healthy** — workspace, dev, postgres, redis all running
- **Ports set** on the dev process (clickable link in sidebar)

## Common Failure Modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `build_failed` with "unknown shorthand flag: -f" | `up_stream` not falling back to standalone `docker-compose` | Fixed in `compose.ex` — verify the fix is deployed |
| 50+ `service_status` calls | Agent polling in a loop because services won't start | Check container logs via `logs` tool. Usually a Dockerfile or image issue |
| No port link in sidebar | Agent didn't pass `ports` to `set_dev_command` | Check `priv/prompts/setup_guide.md` has explicit port instructions |
| "Exec format error" on esbuild/sharp | macOS node_modules binaries in Linux container | Setup guide should tell agent to `npm rebuild` after rebuild |
| "database does not exist" | Agent didn't run `db:create` before migrations | Checklist should be explicit about database creation |
| Agent stops at 7/11 and goes idle | Hit `max_turns: 50` | EvalRunner auto-nudges. If manual, send "Continue with the remaining checklist items." |
| `:pang` / `:nodedown` on RPC | Cookie mismatch or app not running | Re-read cookie file (`cat cookie`), check `epmd -names`, restart app if needed |

## Where Results Live

`evals/<project_name>/<timestamp>.md` — each file contains:
- Outcome (completed/stalled/timeout/failed), duration, message count, tool calls
- Nudge count and checklist progress (e.g. 11/11)
- Service status at completion
- Tool usage breakdown (which MCP tools, how many calls each)
- Error messages if any

## Iterating on Prompts

The loop: **run eval → read result → fix prompt → recompile → restart app → run again.**

Files that control setup agent behavior:
- `priv/prompts/setup_guide.md` — the detailed guide sent as the agent's first message
- `priv/checklists/setup.md` — the checklist template (items the agent works through)
- `lib/boom_looper/chat_agent.ex` — the system prompt (keep under 2000 chars or CLI gets SIGKILL'd)

**Important:** `setup_guide.md` is compiled into `ChatAgent` as a module attribute (`@setup_guide File.read!(...)`). Changes require recompilation. In dev, Phoenix code reloader handles this on the next request, but for eval runs via RPC the app needs a restart to pick up changes.
