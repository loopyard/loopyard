defmodule Loopyard.ChatAgent.ToolConfig do
  @moduledoc """
  Tool configuration for ChatAgent sessions.

  Builds the MCP server map, allowed/disallowed tool lists, and
  provides the default tool module set. Pure functions, no GenServer state.
  """

  # Built-in Claude Code tools for bind-mount agents (they run against
  # the host filesystem, so native Read/Glob/Grep work correctly).
  @builtin_tools_bind_mount [
    "WebSearch",
    "WebFetch",
    "Read",
    "Glob",
    "Grep"
  ]

  # Built-in tools for container-only agents. Read/Glob/Grep are REMOVED
  # because they run host-side — they'd find (or fail to find) files in
  # the wrong place. Everything filesystem-related must go through MCP
  # tools that exec inside the container.
  @builtin_tools_container_only [
    "WebSearch",
    "WebFetch"
  ]

  # Native tools that container-only agents must NEVER use. The
  # `allowed_tools` allowlist alone isn't enough — with
  # --dangerously-skip-permissions the SDK still allows native tools
  # by default. We pass this list as `disallowed_tools` to make the
  # block explicit and survive any future allowlist holes.
  #
  # Bash escape was the smoking gun: agents would `cd /Users/.../loopyard`
  # and edit the host clone, while the running container kept reading
  # the docker volume copy. Edit/Write/Read with absolute paths did
  # the same thing.
  @denied_native_tools_for_container_agents [
    "Bash",
    "Edit",
    "Write",
    "Read",
    "Glob",
    "Grep",
    "MultiEdit",
    "NotebookEdit",
    # Task spawns a sub-agent that shares our MCP session but has its
    # own synthetic agent_id. Every MCP tool call the sub-agent makes
    # is rejected by Loopyard.Tool.authorize_agent/2 ("agent_id
    # mismatch"), silently looping until it burns tokens or gives up.
    # Sub-agents would also violate our workspace boundary (one agent
    # = one workspace_id). Until we design sub-agent identity properly,
    # disable Task.
    "Task",
    # The native AskUserQuestion can't reach our UI / round-trip in headless
    # mode. Route questions through the `ask_user` MCP tool instead, which shows
    # an interactive card and waits for the answer (Loopyard.Harness.Questions).
    "AskUserQuestion"
  ]

  @doc "Returns the list of native tools denied for container-only agents."
  def denied_native_tools_for_container_agents, do: @denied_native_tools_for_container_agents

  @doc """
  Returns the default tool modules for a ChatAgent session.

  Agents are scoped to a single workspace. They do NOT get the Agents
  toolkit (spawn/message/stop other agents) — that was a usability and
  security disaster: agents would auto-spawn siblings and cross
  workspace boundaries. If an agent-to-agent tool comes back, it MUST
  be restricted to the same workspace and gated behind explicit user
  opt-in.
  """
  def default_tools do
    [Loopyard.Tools.Container, Loopyard.Tools.Secrets, Loopyard.Tools.AgentFiles]
  end

  # Control-plane tools exposed to an in-container ACP harness over HTTP MCP
  # (`Loopyard.MCP.ToolRouter`). Deliberately a SUBSET of the full toolkit: an
  # in-container ACP agent already has native Read/Write/Edit/Bash against the
  # mounted code volume, so the filesystem/exec tools (Exec, ReadFile, WriteFile,
  # Edit, Grep, Glob, Tree, …) would be redundant — worse, two ways to edit the
  # same tree. What native tools CAN'T reach is Loopyard's control plane: ports,
  # service lifecycle, the approval-gated fork/integrate/delete flows, the
  # human-in-the-loop ask/secret round-trips, and the URL helpers. That's this
  # list. Adding a tool here exposes it over the network bridge — it must be
  # workspace-scoped and, for anything boundary-crossing, approval-gated.
  alias Loopyard.Tools.Container
  alias Loopyard.Tools.Secrets
  alias Loopyard.Tools.AgentFiles

  @acp_control_plane_tools [
    # Container / service control plane
    Container.Ports,
    Container.WorkspaceInfo,
    Container.ServiceContainers,
    Container.InspectService,
    Container.InspectEnv,
    Container.DockerCompose,
    Container.Logs,
    Container.ProbeHttp,
    Container.Git,
    # Linking helpers (return URLs the agent embeds in replies)
    Container.AppUrl,
    Container.FileUrl,
    # Human-in-the-loop round-trips (native equivalents can't reach the UI)
    Container.AskUser,
    Container.RequestSecret,
    Secrets.ListSecrets,
    Secrets.GetSecret,
    # Approval-gated boundary crossings
    Container.ProposeFork,
    Container.ProposeIntegrate,
    Container.ProposeDeleteWorkspace,
    # Agent playbooks (setup guides live host-side in priv/, not in the volume)
    AgentFiles.ReadAgentFile,
    # Durable memory: read your own conversation history (harness-portable — the
    # conversation lives in Loopyard, not the harness session). Read-only,
    # token-scoped to the calling agent's own transcript.
    Container.RecallConversation
  ]

  @doc "Tool modules exposed to an in-container ACP harness over the HTTP MCP bridge."
  def acp_control_plane_tools, do: @acp_control_plane_tools

  @doc """
  Tool modules for the OPERATOR agent over the bridge — its project/identity
  control-plane toolkit (`Tools.ControlPlane`: create/list projects, gh, exec in
  its workstation container). The operator runs in-container too, so it reaches
  these over the same bridge, scoped by an `:operator` token.
  """
  def acp_operator_tools, do: Loopyard.Tools.ControlPlane.__tool_server__().tools

  @doc """
  The ACP `mcpServers` spec for one agent (delegates to `Loopyard.MCP`). `scope`
  selects the toolset (`:workspace` default, or `:operator`). Injected into the
  ACP backend's session opts by the Initializer; ignored by the in-process
  ClaudeCode backend.
  """
  def acp_mcp_servers(agent_id, workspace_id, scope \\ :workspace),
    do: Loopyard.MCP.acp_mcp_servers(agent_id, workspace_id, scope)

  @doc """
  Builds the MCP server map from tool modules.

  When `agent_id` is supplied, each entry is configured with
  `assigns: %{agent_id: agent_id}` so tools can verify that any
  `agent_id` the model sends in its JSON params matches the session's
  bound identity (see `Loopyard.Tool.authorize_agent/2`). This turns
  `agent_id` from a "rule the model follows" into a runtime boundary:
  copy-pasting another agent's id into this session is inert — the
  bound id wins.

  Called with just tool_modules (no agent_id) for test harnesses and
  tooling that don't run under a session.
  """
  def build_mcp_servers(tool_modules, agent_id \\ nil) do
    assigns = if agent_id, do: %{agent_id: agent_id}, else: %{}

    Map.new(tool_modules, fn mod ->
      info = mod.__tool_server__()
      {info.name, %{module: mod, assigns: assigns}}
    end)
  end

  @doc "Builds the allowed tools list from tool modules and agent type."
  def build_allowed_tools(tool_modules, container_only?) do
    mcp_tools =
      Enum.flat_map(tool_modules, fn mod ->
        info = mod.__tool_server__()
        server_name = info.name

        Enum.map(info.tools, fn tool_mod ->
          "mcp__#{server_name}__#{tool_mod.__tool_name__()}"
        end)
      end)

    builtins =
      if container_only?, do: @builtin_tools_container_only, else: @builtin_tools_bind_mount

    builtins ++ mcp_tools
  end
end
