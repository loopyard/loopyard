defmodule BoomLooper.ChatAgent.ToolConfig do
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
  # Bash escape was the smoking gun: agents would `cd /Users/.../boomlooper`
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
    "NotebookEdit"
  ]

  @doc "Returns the list of native tools denied for container-only agents."
  def denied_native_tools_for_container_agents, do: @denied_native_tools_for_container_agents

  @doc "Returns the default tool modules for a ChatAgent session."
  def default_tools do
    # Note: Workspace tools removed - agents use direct docker_compose/write_file instead
    [BoomLooper.Tools.Agents, BoomLooper.Tools.Container, BoomLooper.Tools.Secrets]
  end

  @doc "Builds the MCP server map from tool modules."
  def build_mcp_servers(tool_modules) do
    Map.new(tool_modules, fn mod ->
      info = mod.__tool_server__()
      {info.name, mod}
    end)
  end

  @doc "Builds the allowed tools list from tool modules and agent type."
  def build_allowed_tools(tool_modules, container_only?) do
    mcp_tools = Enum.flat_map(tool_modules, fn mod ->
      info = mod.__tool_server__()
      server_name = info.name

      Enum.map(info.tools, fn tool_mod ->
        "mcp__#{server_name}__#{tool_mod.__tool_name__()}"
      end)
    end)

    builtins = if container_only?, do: @builtin_tools_container_only, else: @builtin_tools_bind_mount

    builtins ++ mcp_tools
  end
end
