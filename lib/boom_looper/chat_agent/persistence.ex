defmodule BoomLooper.ChatAgent.Persistence do
  @moduledoc """
  Persistence helpers for ChatAgent state.

  Handles writing agent data, messages, and message updates to the
  append-only agent log. These functions take agent state (or fields
  from it) and perform side effects via `AgentLog.append/2`.
  """

  alias BoomLooper.AgentLog

  @log_version 1

  @doc "Returns the agent log path for a workspace, or nil if no workspace_id."
  def log_path(nil), do: nil
  def log_path(workspace_id) do
    virtual_dir = Path.join([BoomLooper.Workspace.home_dir(), "workspaces", workspace_id])
    Path.join([virtual_dir, ".boomlooper", "workspace", "agents.log"])
  end

  @doc "Persist a new agent entry to the log."
  def persist_agent(state, summary_fn) do
    case log_path(state.workspace_id) do
      nil -> :ok
      path ->
        # Log the full summary so replay produces complete ETS entries
        agent_data = summary_fn.(state) |> Map.delete(:messages)
        AgentLog.append({:agent, state.id, agent_data}, log_path: path, version: @log_version)
    end
  end

  @doc "Persist a message to the log."
  def persist_message(state, msg) do
    case log_path(state.workspace_id) do
      nil -> :ok
      path -> AgentLog.append({:msg, state.id, msg}, log_path: path, version: @log_version)
    end
  end

  @doc "Persist a message update (partial changes) to the log."
  def persist_message_update(state, msg_id, changes) do
    case log_path(state.workspace_id) do
      nil -> :ok
      path -> AgentLog.append({:msg_update, state.id, msg_id, changes}, log_path: path, version: @log_version)
    end
  end
end
