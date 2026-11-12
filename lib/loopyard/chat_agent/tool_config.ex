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

  # Native tools that a HOST-SIDE harness must never use — the deny list the
  # old in-process ClaudeCode backend passed as `disallowed_tools`. That
  # backend is gone: every harness now runs IN its container over ACP, where
  # these native tools are exactly what the agent should use (Bash/Edit/Read
  # against the mounted volume — the container is the boundary), and ACP has
  # no `disallowed_tools` at all (`Harness.ACP` ignores this list; see its
  # moduledoc's known gaps). The Initializer still builds the opt for parity;
  # nothing consumes it on the live path.
  #
  # History, for the day a host-side harness returns: Bash escape was the
  # smoking gun — agents would `cd /Users/.../loopyard` and edit the host
  # clone while the container kept reading the volume copy. Edit/Write/Read
  # with absolute paths did the same thing.
  @denied_native_tools_for_container_agents [
    "Bash",
    "Edit",
    "Write",
    "Read",
    "Glob",
    "Grep",
    "MultiEdit",
    "NotebookEdit",
    # Task/Agent (a harness-native sub-agent) is ALLOWED in-container and is
    # deliberately absent here. On the old in-process path a sub-agent's MCP
    # calls failed `authorize_agent/2` (a synthetic agent_id per sub-agent);
    # over the ACP MCP bridge identity comes from the bearer token in the
    # session's `mcpServers` spec, which the sub-agent shares with its parent
    # (verified live 2026-10-21: a sub-agent called a bridge tool and a native
    # tool without an auth error). Its calls nest under the parent's card —
    # docs/ARCHITECTURE.md "Sub-agents inside the harness".
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
  workspace boundaries. Collaboration is FILES plus the chief of staff:
  agents in one workspace share its tree, `read_workspace` reads a sibling
  branch of the same project (read-only), and messages between agents go
  only through a system agent's `dispatch` (sender-stamped, never able to
  answer a human's decision). If a direct agent-to-agent tool ever comes
  back, it MUST be restricted to the same workspace and gated behind
  explicit user opt-in.
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
    # Shell commands whose output a human can WATCH: exec streams into a live
    # console card as the command runs. The harness's native Bash can't — the
    # Claude SDK reports only elapsed seconds until the command exits, so a long
    # build or test run showed nothing, then everything. Same container the
    # agent's Bash already runs in; no new capability (SECURITY.md → bridge).
    Container.Exec,
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
    Container.RecallConversation,
    # The data channel between sibling branches: read-only file access to the
    # OTHER workspaces of the caller's own project (never another project's,
    # never its secrets, never through the sibling's container). Agents share
    # files, not chat — see docs/SECURITY.md → "Agents working together".
    Container.ReadWorkspace
  ]

  @doc "Tool modules exposed to an in-container ACP harness over the HTTP MCP bridge."
  def acp_control_plane_tools, do: @acp_control_plane_tools

  @doc """
  Tool modules for the OPERATOR agent over the bridge — its project/identity
  control-plane toolkit (`Tools.ControlPlane`: create/list projects, gh, exec in
  its workstation container). The operator runs in-container too, so it reaches
  these over the same bridge, scoped by an `:operator` token.
  """
  def acp_system_tools, do: Loopyard.Tools.ControlPlane.__tool_server__().tools

  @doc false
  def acp_operator_tools, do: acp_system_tools()

  @doc "The in-process toolkits a template's agent gets."
  @spec tools_for(Loopyard.Agents.Template.t()) :: [module()]
  def tools_for(%Loopyard.Agents.Template{tools: :system}), do: [Loopyard.Tools.ControlPlane]
  def tools_for(%Loopyard.Agents.Template{}), do: default_tools()

  @doc """
  The MCP bridge scope a template's tools are served under.
  """
  @spec bridge_scope(Loopyard.Agents.Template.t()) :: :workspace | :system
  def bridge_scope(%Loopyard.Agents.Template{tools: :system}), do: :system
  def bridge_scope(%Loopyard.Agents.Template{}), do: :workspace

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
