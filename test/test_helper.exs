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
# Elixir 1.19's parallel compiler occasionally leaves lib modules
# with on-disk .beam files but NOT loaded into the runtime code
# tracker at the moment a test file compiles. The failure shapes:
#
#   "Module.__struct__/1 is undefined, cannot expand struct"
#   "function Module.fun/arity is undefined (module not available)"
#
# The .beam is right there (we can see it in _build/test/lib/…),
# but `Module.function/arity` resolution fails because the tracker
# hasn't indexed it yet.
#
# Workaround: preload every compiled BoomLooper.* module so it's
# guaranteed to be in the loader's index before any test starts.
# Walking the ebin dir keeps this list self-maintaining — we don't
# have to curate a list of every Tool module / every event struct.
_ =
  for pattern <- [
        "_build/test/lib/boom_looper/ebin/Elixir.BoomLooper.*.beam",
        "_build/test/lib/boom_looper/ebin/Elixir.BoomLooperWeb.*.beam"
      ],
      path <- Path.wildcard(pattern) do
    path
    |> Path.basename(".beam")
    |> String.replace_prefix("Elixir.", "")
    |> String.to_atom()
    |> Code.ensure_loaded()
  end

# Also cover the Toolkit's __tool_server__/0 side — it builds a list
# of child modules that the test mcp_tool_names walk then dereferences.
# These are always present but historically hit the race hardest.
[
  # Event structs reached across module boundaries (tests
  # pattern-match on them via `assert_receive`).
  BoomLooper.Events.ChatAgent.Started,
  BoomLooper.Events.ChatAgent.Stopped,
  BoomLooper.Events.ChatAgent.Booting,
  BoomLooper.Events.ChatAgent.BootStatus,
  BoomLooper.Events.ChatAgent.BootFailed,
  BoomLooper.Events.ChatAgent.Removed,
  BoomLooper.Events.ChatAgent.Renamed,
  BoomLooper.Events.ChatAgent.Resumed,
  BoomLooper.Events.ChatAgent.StatusChanged,
  BoomLooper.Events.ChatAgent.Quarantined,
  BoomLooper.Events.ChatAgent.Released,
  BoomLooper.Events.ChatAgentMessage.Message,
  BoomLooper.Events.ChatAgentMessage.TextDelta,
  BoomLooper.Events.ChatAgentMessage.StreamOutput,
  BoomLooper.Events.Terminal.Output,
  BoomLooper.Events.Terminal.Clear,
  BoomLooper.Events.Terminal.Exit,
  BoomLooper.Events.DockerObserver.Changed,
  BoomLooper.Events.DockerObserver.Reset,
  BoomLooper.Events.DockerObserver.Disconnected,
  BoomLooper.Events.DockerObserver.Reconnected,
  BoomLooper.Events.IexSession.Changed,
  BoomLooper.Events.SourceSync.Updated,
  BoomLooper.Events.WorkspaceServices.ServicesUpdated,
  BoomLooper.Events.WorkspaceServices.ComposeResult,
  # Agent event structs — referenced from chat-agent tests.
  BoomLooper.Agent.Event.TextDelta,
  BoomLooper.Agent.Event.Text,
  BoomLooper.Agent.Event.ToolCall,
  BoomLooper.Agent.Event.ToolResult,
  BoomLooper.Agent.Event.SessionResult,
  BoomLooper.Agent.Event.RateLimitStatus,
  BoomLooper.Agent.Event.AuthStatus,
  BoomLooper.Agent.Event.Thinking,
  BoomLooper.Agent.Event.ThinkingDelta,
  BoomLooper.Agent.Event.ServerTool,
  BoomLooper.Agent.Event.SystemEvent,
  # Domain structs reached across files.
  BoomLooper.Workspace.ServiceStatus.Service,
  # Tool modules use the BoomLooper.Tool macro which injects
  # `__tool_name__/0`. Under full-suite load, the Toolkit's walk
  # across Tools.Container.* occasionally hits a not-yet-loaded
  # module and raises UndefinedFunctionError. Same race class.
  BoomLooper.Tool,
  BoomLooper.Tools.Container,
  BoomLooper.Tools.Container.AppUrl,
  BoomLooper.Tools.Container.DockerCompose,
  BoomLooper.Tools.Container.Edit,
  BoomLooper.Tools.Container.Exec,
  BoomLooper.Tools.Container.FileUrl,
  BoomLooper.Tools.Container.Glob,
  BoomLooper.Tools.Container.Grep,
  BoomLooper.Tools.Container.InspectEnv,
  BoomLooper.Tools.Container.InspectService,
  BoomLooper.Tools.Container.Logs,
  BoomLooper.Tools.Container.MultiEdit,
  BoomLooper.Tools.Container.Ports,
  BoomLooper.Tools.Container.ProbeHttp,
  BoomLooper.Tools.Container.ReadFile,
  BoomLooper.Tools.Container.ReadFiles,
  BoomLooper.Tools.Container.ServiceContainers,
  BoomLooper.Tools.Container.Tree,
  BoomLooper.Tools.Container.Volumes,
  BoomLooper.Tools.Container.WorkspaceInfo,
  BoomLooper.Tools.Container.WriteFile,
  # Subscriber behaviour modules — tests call `mod.module_info(:attributes)`
  # and hit the same parallel-compile load race.
  BoomLooper.Events.ChatAgent.Subscriber,
  BoomLooper.Events.ChatAgentMessage.Subscriber,
  BoomLooper.Events.DockerObserver.Subscriber,
  BoomLooper.Events.SourceSync.Subscriber,
  BoomLooper.Events.WorkspaceServices.Subscriber,
  BoomLooper.Events.WorkspaceSetup,
  BoomLooper.Events.WorkspaceSetup.Subscriber,
  BoomLooper.Events.WorkspaceSetup.Started,
  BoomLooper.Events.WorkspaceSetup.PhaseStarted,
  BoomLooper.Events.WorkspaceSetup.PhaseCompleted,
  BoomLooper.Events.WorkspaceSetup.PhaseProgress,
  BoomLooper.Events.WorkspaceSetup.Completed,
  BoomLooper.Events.WorkspaceSetup.Failed,
  BoomLooper.Events.WorkspaceSetup.RetryScheduled,
  BoomLooper.Workspace.Setup,
  BoomLooper.Workspace.Setup.Error,
  BoomLooper.Workspace.Setup.ProgressParser,
  # Helpers reached across test files.
  BoomLooper.ChatAgent.OSProcess,
  BoomLooper.Saga,
  BoomLooper.Saga.Journal,
  BoomLooper.Saga.Recorder,
  # Tool macros from ClaudeCode.MCP.Server generate submodules
  # (e.g. Tools.Secrets.GetSecret) that get walked by mcp_tool_names.
  BoomLooper.Tools.Secrets,
  BoomLooper.Tools.Secrets.GetSecret,
  BoomLooper.Tools.Secrets.ListSecrets,
  BoomLooper.Tools.Workspace,
  BoomLooper.Tools.Workspace.SetSystemPrompt,
  BoomLooper.Tools.Workspace.SetWorkspaceName,
  BoomLooper.Tools.AgentFiles,
  BoomLooper.Tools.AgentFiles.ReadAgentFile,
  BoomLooper.Tools.Container.Helpers,
  BoomLooper.Tools.Container.ProbeFormatter
]
|> Enum.each(&Code.ensure_loaded!/1)

# Docker tests genuinely need more than 2s — `docker version` alone
# can take 1-2s on a cold daemon, and most :docker tests do volume
# create + rsync + container exec. CI's docker-e2e job sets
# BOOMLOOPER_LONG_TIMEOUTS=1 to bump the suite-wide default for that
# run. Local default stays tight (2s) so Process.sleep regressions
# still fail loudly.
default_timeout =
  case System.get_env("BOOMLOOPER_LONG_TIMEOUTS") do
    "1" -> 30_000
    _ -> 2_000
  end

ExUnit.start(
  exclude: [:docker, :terminal, :ssh, :recovery, :slow, :macos],
  timeout: default_timeout
)
