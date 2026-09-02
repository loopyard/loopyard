# LOOPYARD_HOME is redirected to .loopyard_home/ and reset in
# config/test.exs — NOT here. This file runs after the application has
# already booted and read the home dir, which is far too late. See the
# comment there before moving any of it back.

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
# Workaround: preload every compiled Loopyard.* module so it's
# guaranteed to be in the loader's index before any test starts.
# Walking the ebin dir keeps this list self-maintaining — we don't
# have to curate a list of every Tool module / every event struct.
_ =
  for pattern <- [
        "_build/test/lib/loopyard/ebin/Elixir.Loopyard.*.beam",
        "_build/test/lib/loopyard/ebin/Elixir.LoopyardWeb.*.beam"
      ],
      path <- Path.wildcard(pattern) do
    path
    |> Path.basename(".beam")
    |> String.replace_prefix("Elixir.", "")
    # Module names read from OUR compiled beams — bounded by the build, not
    # by input; the atom may not exist yet, which is the point of loading it.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    |> String.to_atom()
    |> Code.ensure_loaded()
  end

# Also cover the Toolkit's __tool_server__/0 side — it builds a list
# of child modules that the test mcp_tool_names walk then dereferences.
# These are always present but historically hit the race hardest.
[
  # Event structs reached across module boundaries (tests
  # pattern-match on them via `assert_receive`).
  Loopyard.Events.ChatAgent.Started,
  Loopyard.Events.ChatAgent.Stopped,
  Loopyard.Events.ChatAgent.Booting,
  Loopyard.Events.ChatAgent.BootStatus,
  Loopyard.Events.ChatAgent.BootFailed,
  Loopyard.Events.ChatAgent.Removed,
  Loopyard.Events.ChatAgent.Renamed,
  Loopyard.Events.ChatAgent.Resumed,
  Loopyard.Events.ChatAgent.StatusChanged,
  Loopyard.Events.ChatAgent.Quarantined,
  Loopyard.Events.ChatAgent.Released,
  Loopyard.Events.ChatAgentMessage.Message,
  Loopyard.Events.ChatAgentMessage.TextDelta,
  Loopyard.Events.ChatAgentMessage.StreamOutput,
  Loopyard.Events.Terminal.Output,
  Loopyard.Events.Terminal.Clear,
  Loopyard.Events.Terminal.Exit,
  Loopyard.Events.DockerObserver.Changed,
  Loopyard.Events.DockerObserver.Reset,
  Loopyard.Events.DockerObserver.Disconnected,
  Loopyard.Events.DockerObserver.Reconnected,
  Loopyard.Events.IexSession.Changed,
  Loopyard.Events.SourceSync.Updated,
  Loopyard.Events.WorkspaceServices.ServicesUpdated,
  Loopyard.Events.WorkspaceServices.ComposeResult,
  # Agent event structs — referenced from chat-agent tests.
  Loopyard.Agent.Event.TextDelta,
  Loopyard.Agent.Event.Text,
  Loopyard.Agent.Event.ToolCall,
  Loopyard.Agent.Event.ToolResult,
  Loopyard.Agent.Event.SessionResult,
  Loopyard.Agent.Event.RateLimitStatus,
  Loopyard.Agent.Event.AuthStatus,
  Loopyard.Agent.Event.Thinking,
  Loopyard.Agent.Event.ThinkingDelta,
  Loopyard.Agent.Event.ServerTool,
  Loopyard.Agent.Event.SystemEvent,
  # Domain structs reached across files.
  Loopyard.Workspace.ServiceStatus.Service,
  # Tool modules use the Loopyard.Tool macro which injects
  # `__tool_name__/0`. Under full-suite load, the Toolkit's walk
  # across Tools.Container.* occasionally hits a not-yet-loaded
  # module and raises UndefinedFunctionError. Same race class.
  Loopyard.Tool,
  Loopyard.Tools.Container,
  Loopyard.Tools.Container.AppUrl,
  Loopyard.Tools.Container.DockerCompose,
  Loopyard.Tools.Container.Edit,
  Loopyard.Tools.Container.Exec,
  Loopyard.Tools.Container.FileUrl,
  Loopyard.Tools.Container.Glob,
  Loopyard.Tools.Container.Grep,
  Loopyard.Tools.Container.InspectEnv,
  Loopyard.Tools.Container.InspectService,
  Loopyard.Tools.Container.Logs,
  Loopyard.Tools.Container.MultiEdit,
  Loopyard.Tools.Container.Ports,
  Loopyard.Tools.Container.ProbeHttp,
  Loopyard.Tools.Container.ReadFile,
  Loopyard.Tools.Container.ReadFiles,
  Loopyard.Tools.Container.ServiceContainers,
  Loopyard.Tools.Container.Tree,
  Loopyard.Tools.Container.Volumes,
  Loopyard.Tools.Container.WorkspaceInfo,
  Loopyard.Tools.Container.WriteFile,
  # Subscriber behaviour modules — tests call `mod.module_info(:attributes)`
  # and hit the same parallel-compile load race.
  Loopyard.Events.ChatAgent.Subscriber,
  Loopyard.Events.ChatAgentMessage.Subscriber,
  Loopyard.Events.DockerObserver.Subscriber,
  Loopyard.Events.SourceSync.Subscriber,
  Loopyard.Events.WorkspaceServices.Subscriber,
  Loopyard.Events.WorkspaceSetup,
  Loopyard.Events.WorkspaceSetup.Subscriber,
  Loopyard.Events.WorkspaceSetup.Started,
  Loopyard.Events.WorkspaceSetup.PhaseStarted,
  Loopyard.Events.WorkspaceSetup.PhaseCompleted,
  Loopyard.Events.WorkspaceSetup.PhaseProgress,
  Loopyard.Events.WorkspaceSetup.Completed,
  Loopyard.Events.WorkspaceSetup.Failed,
  Loopyard.Events.WorkspaceSetup.RetryScheduled,
  Loopyard.Workspace.Setup,
  Loopyard.Workspace.Setup.Error,
  Loopyard.Workspace.Setup.ProgressParser,
  # Helpers reached across test files.
  Loopyard.ChatAgent.OSProcess,
  Loopyard.Saga,
  Loopyard.Saga.Journal,
  Loopyard.Saga.Recorder,
  # Tool macros from ClaudeCode.MCP.Server generate submodules
  # (e.g. Tools.Secrets.GetSecret) that get walked by mcp_tool_names.
  Loopyard.Tools.Secrets,
  Loopyard.Tools.Secrets.GetSecret,
  Loopyard.Tools.Secrets.ListSecrets,
  Loopyard.Tools.Workspace,
  Loopyard.Tools.Workspace.SetSystemPrompt,
  Loopyard.Tools.Workspace.SetWorkspaceName,
  Loopyard.Tools.AgentFiles,
  Loopyard.Tools.AgentFiles.ReadAgentFile,
  Loopyard.Tools.Container.Helpers,
  Loopyard.Tools.Container.ProbeFormatter
]
|> Enum.each(&Code.ensure_loaded!/1)

# Docker tests genuinely need more than 2s — `docker version` alone
# can take 1-2s on a cold daemon, and most :docker tests do volume
# create + rsync + container exec. CI's docker-e2e job sets
# LOOPYARD_LONG_TIMEOUTS=1 to bump the suite-wide default for that
# run. Local default stays tight (2s) so Process.sleep regressions
# still fail loudly.
default_timeout =
  case System.get_env("LOOPYARD_LONG_TIMEOUTS") do
    "1" -> 30_000
    _ -> 2_000
  end

ExUnit.start(
  exclude: [:docker, :terminal, :ssh, :recovery, :slow, :macos],
  timeout: default_timeout
)
