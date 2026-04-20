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
    virtual_dir = BoomLooper.Workspace.compose_dir(workspace_id)
    Path.join([virtual_dir, ".boomlooper", "workspace", "agents.log"])
  end

  @doc "Persist a new agent entry to the log."
  def persist_agent(state, summary_fn) do
    case log_path(state.workspace_id) do
      nil -> :ok
      path ->
        # Log the full summary so replay produces complete ETS entries
        agent_data = summary_fn.(state) |> Map.delete(:messages)
        safe_append({:agent, state.id, agent_data}, path, state.id, state.workspace_id)
    end
  end

  @doc "Persist a message to the log."
  def persist_message(state, msg) do
    case log_path(state.workspace_id) do
      nil -> :ok
      path -> safe_append({:msg, state.id, msg}, path, state.id, state.workspace_id)
    end
  end

  @doc "Persist a message update (partial changes) to the log."
  def persist_message_update(state, msg_id, changes) do
    case log_path(state.workspace_id) do
      nil -> :ok
      path ->
        safe_append({:msg_update, state.id, msg_id, changes}, path, state.id, state.workspace_id)
    end
  end

  # Catch-and-report append. Historically AgentLog.append/2 raised on
  # disk-full / permission errors, which bubbled up through persist_*
  # into ChatAgent handle_info and crashed the GenServer. With 5
  # crashes in 60s the RestartController quarantined it. Net effect: a
  # single disk-full event quarantined every agent in the workspace,
  # making "my disk filled up" an outage that needed manual
  # intervention.
  #
  # Now: we catch raises, emit telemetry with the reason, and return
  # :ok so the caller keeps serving from memory. Persistence failure
  # is OBSERVABLE at /system/events but doesn't kill agents.
  # See plans/agent-sanity.md #17.
  defp safe_append(event, path, agent_id, workspace_id) do
    try do
      AgentLog.append(event, log_path: path, version: @log_version)
      notify_checkpointer(workspace_id)
      :ok
    rescue
      e ->
        :telemetry.execute(
          [:boom_looper, :persistence, :error],
          %{count: 1},
          %{agent_id: agent_id, path: path, reason: Exception.message(e), kind: elem(event, 0)}
        )

        require Logger

        Logger.warning(
          "[Persistence] Failed to append #{elem(event, 0)} for agent #{agent_id} " <>
            "to #{path}: #{Exception.message(e)}. Agent keeps serving from memory but " <>
            "this change will NOT survive a BoomLooper restart. Fix the disk/permissions " <>
            "and restart the agent."
        )

        :ok
    catch
      kind, reason ->
        :telemetry.execute(
          [:boom_looper, :persistence, :error],
          %{count: 1},
          %{agent_id: agent_id, path: path, reason: inspect({kind, reason}), kind: elem(event, 0)}
        )

        :ok
    end
  end

  # Notify the per-workspace Checkpointer that a record was written.
  # Soft dependency — if the Checkpointer isn't registered (e.g. in
  # isolated tests), silently skip. Never blocks persistence.
  defp notify_checkpointer(workspace_id) do
    case Registry.lookup(BoomLooper.AgentLog.CheckpointerRegistry, workspace_id) do
      [{pid, _}] -> BoomLooper.AgentLog.Checkpointer.notify_write(pid)
      [] -> :ok
    end
  rescue
    # Registry unavailable in a stripped-down test env — don't crash
    # the GenServer over a failed observability hop.
    _ -> :ok
  end
end
