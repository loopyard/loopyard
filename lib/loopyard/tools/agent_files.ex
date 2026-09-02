defmodule Loopyard.Tools.AgentFiles do
  @moduledoc """
  MCP toolkit for reading an agent's own definition files.

  The agent is a folder on disk — `agent.md` plus arbitrary support
  files (guides, stack templates, etc.). This toolkit exposes a
  single tool (`read_agent_file`) that lets the agent pull those
  files on demand. Sandbox: reads are scoped to the single coding
  agent's template folder only (`Loopyard.Agents.Template.folder/1`).

  This toolkit is always-on for every agent — it's part of the base
  capability, not an opt-in MCP server. An agent cannot function
  without the ability to read its own instructions.
  """

  alias Loopyard.Tools.AgentFiles

  @tools [AgentFiles.ReadAgentFile]

  def __tool_server__ do
    %{name: "loopyard-agent-files", tools: @tools}
  end
end
