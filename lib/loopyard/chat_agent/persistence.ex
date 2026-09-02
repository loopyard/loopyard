defmodule Loopyard.ChatAgent.Persistence do
  @moduledoc """
  Persistence helpers for ChatAgent state.

  Handles writing agent data, messages, and message updates to the
  append-only agent log. These functions take agent state (or fields
  from it) and perform side effects via `AgentLog.append/2`.
  """

  alias Loopyard.AgentLog

  @log_version 1

  @doc "Returns the agent log path for a workspace, or nil if no workspace_id."
  def log_path(nil), do: nil

  def log_path(workspace_id) do
    virtual_dir = Loopyard.Workspace.compose_dir(workspace_id)
    Path.join([virtual_dir, ".loopyard", "workspace", "agents.log"])
  end

  @doc """
  A workstation identity's SYSTEM agents' log — every workspace-less agent of
  that identity, in one file with one writer (the SystemGroup's Checkpointer),
  mirroring the per-workspace `agents.log`.
  """
  def system_log_path(identity),
    do: Path.join(Loopyard.Workstation.dir(identity), "agents.log")

  @doc """
  The operator's OLD log, from before system agents had a group — read by the
  migration only (`Loopyard.Agents.migrate!/1`).
  """
  def operator_log_path(identity),
    do: Path.join(Loopyard.Workstation.dir(identity), "operator-agent.log")

  @doc "Where an agent's log lives, from its state or summary; nil = no persistence."
  def log_path_for(state), do: state_log_path(state)

  # Where THIS agent's log lives: by SCOPE — a workspace agent → its workspace
  # log; a system agent → its identity's agents log; otherwise none. A row
  # from before scopes existed (the operator: no workspace, a container) is a
  # system agent too.
  defp state_log_path(%{scope: :system, workstation_identity: id}) when is_binary(id),
    do: system_log_path(id)

  defp state_log_path(%{workspace_id: ws}) when is_binary(ws), do: log_path(ws)

  defp state_log_path(%{workstation_identity: id, container: c})
       when is_binary(id) and is_binary(c),
       do: system_log_path(id)

  defp state_log_path(_), do: nil

  @doc "Persist a new agent entry to the log."
  def persist_agent(state, summary_fn) do
    case state_log_path(state) do
      nil ->
        :ok

      path ->
        # Log the full summary so replay produces complete ETS entries
        agent_data = summary_fn.(state) |> Map.delete(:messages)
        safe_append({:agent, state.id, agent_data}, path, state.id, scope_key(state))
    end
  end

  @doc "Persist a message to the log."
  def persist_message(state, msg) do
    case state_log_path(state) do
      nil -> :ok
      path -> safe_append({:msg, state.id, msg}, path, state.id, scope_key(state))
    end
  end

  @doc "Persist a message update (partial changes) to the log."
  def persist_message_update(state, msg_id, changes) do
    case state_log_path(state) do
      nil ->
        :ok

      path ->
        safe_append({:msg_update, state.id, msg_id, changes}, path, state.id, scope_key(state))
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
  defp scope_key(state), do: Loopyard.Agents.scope_key(state)

  defp safe_append(event, path, agent_id, key) do
    try do
      append_via_writer(event, path, key)
      :ok
    rescue
      e ->
        :telemetry.execute(
          [:loopyard, :persistence, :error],
          %{count: 1},
          %{agent_id: agent_id, path: path, reason: Exception.message(e), kind: elem(event, 0)}
        )

        require Logger

        Logger.warning(
          "[Persistence] Failed to append #{elem(event, 0)} for agent #{agent_id} " <>
            "to #{path}: #{Exception.message(e)}. Agent keeps serving from memory but " <>
            "this change will NOT survive a Loopyard restart. Fix the disk/permissions " <>
            "and restart the agent."
        )

        :ok
    catch
      kind, reason ->
        :telemetry.execute(
          [:loopyard, :persistence, :error],
          %{count: 1},
          %{agent_id: agent_id, path: path, reason: inspect({kind, reason}), kind: elem(event, 0)}
        )

        :ok
    end
  end

  # Write a record to the agent log. When a per-workspace Checkpointer is
  # registered (production), route the append THROUGH it so it is the single
  # writer — appends can't interleave with compaction, which is what fixes the
  # silent record-loss race. When there's no Checkpointer (isolated tests,
  # not-yet-started workspace), there's also no concurrent compactor, so a
  # direct append is race-free too. Raises on failure (caught by safe_append).
  defp append_via_writer(event, path, key) do
    case checkpointer_for(key) do
      nil ->
        AgentLog.append(event, log_path: path, version: @log_version)

      pid ->
        # Non-blocking cast — the Checkpointer serializes the write against
        # compaction and logs/telemetry's its own failures (it can't reply).
        Loopyard.AgentLog.Checkpointer.append(pid, event)
    end
  end

  defp checkpointer_for(nil), do: nil

  defp checkpointer_for(key) do
    case Registry.lookup(Loopyard.AgentLog.CheckpointerRegistry, key) do
      [{pid, _}] -> pid
      [] -> nil
    end
  rescue
    # Registry unavailable in a stripped-down test env.
    _ -> nil
  end
end
