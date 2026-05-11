# Testing

## Philosophy

**Every feature needs tests.** Write failing tests first, then implement. This prevents regressions that waste hours of debugging.

**No file over ~300 lines.** When a module gets extracted, it gets its own test file. Don't let test files grow into monoliths either.

## Running tests

```bash
mix test                           # Default (excludes :docker, :slow, :terminal, :ssh, :recovery)
mix test --trace                   # Verbose output
mix test --include docker          # Include Docker integration tests
mix test path/to/test.exs          # Run specific file
mix test path/to/test.exs:42       # Run specific test at line 42
```

Tests must finish in under 30 seconds. Per-test timeout is 2 seconds. If a test is slow, tag it and exclude it — don't tolerate slow test suites.

## Test tags

| Tag | Meaning | When to use |
|-----|---------|-------------|
| `@tag :docker` | Requires Docker daemon | Container operations, compose lifecycle, volume I/O |
| `@tag :slow` | Takes >1 second | Network calls, large data operations |
| `@tag :terminal` | Requires PTY | Terminal echo, script(1) tests |
| `@tag :ssh` | Requires SSH server | SSH connection tests |
| `@tag :recovery` | Tests crash recovery | Agent restart, session backoff |

All excluded by default in `test_helper.exs`.

## Test helpers

```elixir
# Start an agent under the correct workspace supervisor
{:ok, _pid} = BoomLooper.TestHelpers.start_agent(
  id: "test-#{:rand.uniform(100_000)}",
  name: "Test Agent",
  working_dir: tmp_dir,
  bind_mount: tmp_dir,
  started_by: "test"
)
```

Always use random IDs to avoid test interference. Always clean up in `on_exit`:

```elixir
on_exit(fn ->
  try do
    BoomLooper.ChatAgent.stop_agent(id)
  catch
    :exit, _ -> :ok
  end
  Process.sleep(50)
end)
```

**ETS tables:** `StateKeeper.ensure_tables!/0` is idempotent and available for test setup. The application supervisor creates tables on boot, so most tests don't need to call this.

## Test contracts

### Tool modules

Every tool module must export the 4-function interface and have a valid JSON schema:

```elixir
for tool_mod <- Container.__tool_server__().tools do
  assert function_exported?(tool_mod, :__tool_name__, 0)
  assert function_exported?(tool_mod, :__description__, 0)
  assert function_exported?(tool_mod, :input_schema, 0)
  assert function_exported?(tool_mod, :execute, 2)

  schema = tool_mod.input_schema()
  assert schema["type"] == "object"
end
```

Test tool `execute/2` directly with atom-key params (matching what the SDK sends):

```elixir
assert {:error, msg} = Exec.execute(%{agent_id: "nonexistent", command: "echo hi"}, %{})
assert msg =~ "no workspace"
```

Test file: `test/boom_looper/tools/container_test.exs`

### Message IDs

Every message must have a unique, non-nil `:id`:

```elixir
for msg <- state.messages do
  assert msg[:id] != nil
end

ids = Enum.map(state.messages, & &1[:id])
assert ids == Enum.uniq(ids)
```

Test file: `test/boom_looper/chat_agent_test.exs`

### Input validation

Tool inputs are validated at boundaries — paths, string lengths, timeouts, null bytes:

```elixir
# Path traversal rejected
assert {:error, msg} = WriteFile.execute(%{agent_id: "x", path: "../etc/passwd", content: "x"}, %{})
assert msg =~ "must be within /workspace"

# Oversized input rejected
big = String.duplicate("x", 10_001)
assert {:error, msg} = Exec.execute(%{agent_id: "x", command: big}, %{})
assert msg =~ "byte limit"
```

Test files: `test/boom_looper/tools/container_test.exs`

### Container persistence

ServiceManager does NOT tear down containers on terminate:

```elixir
GenServer.stop(pid, :normal)
refute Process.alive?(pid)
# Containers still running
```

Test file: `test/boom_looper/service_manager_terminate_test.exs`

## Test file mapping

| Source | Test |
|--------|------|
| `lib/boom_looper/chat_agent.ex` | `test/boom_looper/chat_agent_test.exs` |
| `lib/boom_looper/chat_agent/prompt.ex` | `test/boom_looper/chat_agent/prompt_test.exs` |
| `lib/boom_looper/chat_agent/tool_config.ex` | `test/boom_looper/chat_agent/tool_config_test.exs` |
| `lib/boom_looper/chat_agent/persistence.ex` | `test/boom_looper/chat_agent/persistence_test.exs` |
| `lib/boom_looper/tools/container.ex` | `test/boom_looper/tools/container_test.exs` |
| `lib/boom_looper/tool.ex` | `test/boom_looper/tool_test.exs` |
| `lib/boom_looper/registry_helper.ex` | `test/boom_looper/registry_helper_test.exs` |
| `lib/boom_looper/workspace_registry.ex` | `test/boom_looper/workspace_registry_test.exs` |
| `lib/boom_looper/volume_io.ex` | `test/boom_looper/volume_io_test.exs` (`:docker`) |
| `lib/boom_looper/volume_cloner.ex` | `test/boom_looper/volume_cloner_test.exs` |
| `lib/boom_looper/stream_buffer.ex` | `test/boom_looper/stream_buffer_test.exs` |
| `lib/boom_looper/compose.ex` | `test/boom_looper/compose_test.exs` |
| `lib/boom_looper/docker.ex` | `test/boom_looper/docker_test.exs` |
| `lib/boom_looper/event_log.ex` | `test/boom_looper/event_log_test.exs` |
| `lib/boom_looper/project_registry.ex` | `test/boom_looper/project_registry_test.exs` |
| `lib/boom_looper/terminal.ex` | `test/boom_looper/terminal_test.exs` |
| `lib/boom_looper/workspace/service_manager.ex` | `test/boom_looper/service_manager_terminate_test.exs` |
| `lib/boom_looper_web/live/message_live.ex` | `test/boom_looper_web/live/message_live_test.exs` |
| `lib/boom_looper_web/live/workspace_live/agent_events.ex` | `test/boom_looper_web/live/workspace_live/agent_events_test.exs` |
| `lib/boom_looper_web/live/workspace_live/docker_events.ex` | `test/boom_looper_web/live/workspace_live/docker_events_test.exs` |
| `lib/boom_looper_web/channels/terminal_channel.ex` | `test/boom_looper_web/channels/terminal_channel_test.exs` |

## Rules

- **Failing test first.** New feature: red before green. Bug fix: write a test that reproduces the bug, watch it fail, then fix.
- **Test the real path, not a mock of it.** If production goes through GenServer → ETS → PubSub, the test does too. Stub at the boundary (Docker, Claude CLI), not in the middle.
- **No mocks of our own code.** If you're tempted to mock a context module, refactor to pass data instead.
- **Inject dependencies at the boundary.** `Docker.exec_in`, `VolumeIO`, and `ChatAgent.Backend` are the boundaries; tests configure or stub these, not the callers.

## When to write tests

- **New feature**: Write tests BEFORE implementation. Red/green cycle.
- **Bug fix**: Write a failing test that reproduces the bug, then fix it.
- **Refactor**: Existing tests must still pass. Add tests if coverage is weak.
- **New MCP tool**: Test that execute/2 handles errors, validates inputs.
- **New LiveView route**: Test that it renders, handles PubSub updates, navigates correctly.
- **Extracted module**: Gets its own test file immediately. Don't defer.
- **Pure functions**: Always test — they're the cheapest tests to write.

## Docker boundary

Agent tools must go through Docker, never the host filesystem. Tests should verify this boundary:

- **Tool tests** should verify operations go through `Docker.exec_in` or `VolumeIO`, never host `File` operations. If a tool reads a file, it should use `VolumeIO.read_file/2` (which runs a `docker run` under the hood), not `File.read/1`.
- **Truncation tests** should verify agents get bounded output. `Helpers.truncate_for_agent/1` caps tool output at ~80 lines. Test that long output is truncated and short output passes through unchanged.
- **Tests tagged `:docker`** require a running Docker daemon. These test the real Docker path (volume I/O, container exec, compose lifecycle). Excluded from default runs.

## Known test issues

- Claude CLI not available in test environment — `send_message` triggers stream errors (expected, non-blocking)
- Docker tests excluded by default — run with `--include docker`
- Some tests may flake under full-suite load due to 2s timeout — if a test consistently needs more time, tag it `:slow`
