# Elixir 1.19 parallel compiler can schedule a test module before the
# lib modules that define its referenced structs. The tiny publisher
# modules (`defmodule Changed, do: defstruct([])` inside
# `BoomLooper.Events.DockerObserver` etc.) are especially prone — the
# parent module compiles fine but the nested struct isn't visible to a
# test file compiled in the same pass. Eagerly load the Events
# hierarchy + a few hotspot modules so every struct referenced in
# `%Events.X.Y{}` expansion already has an atom table entry when the
# compiler expands it. Costs milliseconds at boot; saves us a clean
# rebuild on every flaky CI run.
for mod <- [
      BoomLooper.Events.ChatAgent,
      BoomLooper.Events.ChatAgentMessage,
      BoomLooper.Events.DockerObserver,
      BoomLooper.Events.IexSession,
      BoomLooper.Events.SourceSync,
      BoomLooper.Events.Terminal,
      BoomLooper.Events.WorkspaceServices,
      BoomLooper.Agent.Event,
      BoomLooper.Agent.Event.RateLimitStatus,
      BoomLooper.Agent.Event.AuthStatus,
      BoomLooper.Agent.Event.SessionResult,
      BoomLooper.Agent.Event.Text,
      BoomLooper.Agent.Event.TextDelta,
      BoomLooper.Agent.Event.ToolCall,
      BoomLooper.Agent.Event.ToolResult
    ] do
  Code.ensure_loaded!(mod)
end

# Set BOOMLOOPER_HOME to a local dir so tests don't write to ~/.boomlooper
boomlooper_home = Path.join(File.cwd!(), ".boomlooper_home")

# Clean up stale projects.json from previous test runs
projects_json = Path.join(boomlooper_home, "projects.json")
File.rm(projects_json)

File.mkdir_p!(boomlooper_home)
System.put_env("BOOMLOOPER_HOME", boomlooper_home)

#
# Tags excluded from the default `mix test` run to keep it under 30s.
# Run a specific bucket with `mix test --include <tag>`.
#
#   :docker    — needs a running Docker daemon
#   :terminal  — boots a real PTY via script(1) + sleeps; integration-only
#   :ssh       — boots the embedded SSH server, slow handshakes
#   :recovery  — agent crash/recovery scenarios, multi-second sleeps
#   :slow      — anything else with sleeps >1s
#   :macos     — host-specific stat shellouts
#
#
# Hard per-test timeout. ExUnit's default is 60s — way too generous.
# Anything that needs more than 2s is, by definition, slow and must be
# tagged so it gets excluded above. The whole default suite must finish
# in under 30s; this timeout is the tripwire that makes "I'll just add
# a Process.sleep" fail loudly instead of quietly eating seconds.
#
# If a test legitimately needs more time, it must either be tagged
# (:docker / :slow / :terminal / etc.) or explicitly opt out with
# `@tag timeout: 5_000` and a comment justifying why.
#
ExUnit.start(
  exclude: [:docker, :terminal, :ssh, :recovery, :slow, :macos],
  timeout: 2_000
)
