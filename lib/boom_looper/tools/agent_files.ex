defmodule BoomLooper.Tools.AgentFiles do
  @moduledoc """
  MCP toolkit for reading an agent's own definition files.

  Every agent is a folder on disk — `agent.md` plus arbitrary support
  files (guides, stack templates, etc.). This toolkit exposes a
  single tool (`read_agent_file`) that lets the agent pull those
  files on demand. Sandbox: reads are scoped to the agent's own
  folder only, via the registry lookup on the agent's `agent_type`.

  This toolkit is always-on for every agent — it's part of the base
  capability, not an opt-in MCP server. An agent cannot function
  without the ability to read its own instructions.
  """

  alias BoomLooper.Tools.AgentFiles

  @tools [AgentFiles.ReadAgentFile]

  def __tool_server__ do
    %{name: "boom-looper-agent-files", tools: @tools}
  end
end
