defmodule Loopyard.ChatAgent.Lifecycle do
  @moduledoc """
  Agent lifecycle operations that live OUTSIDE the ChatAgent GenServer:
  starting a stopped agent, removing one, the booting-stub bookkeeping
  (register/update/fail), and the ETS-backed `list_agents/0` roster.

  These are pure module functions over ETS / Registry / the DynamicSupervisor
  — none of them touch live GenServer state — so they were split out of
  `Loopyard.ChatAgent` to keep that module under its size cap. `ChatAgent`
  re-exposes the public ones via `defdelegate`, so every external call site
  (LiveView, AgentBoot, tests) is unchanged.
  """

  alias Loopyard.AgentLog
  alias Loopyard.ChatAgent.Persistence
  alias Loopyard.Events

  @ets_table :chat_agents

  # How long an agent is allowed to stay in :booting before we
  # conclude its boot Task died without running its failure handler
  # (task supervisor shutdown, OS kill, etc.) and forcibly surface
  # it as :crashed so the UI's Start button appears. Anything under
  # this window is still legitimately booting.
  @stuck_booting_seconds 300

  @doc "Start a stopped/crashed agent — starts a new GenServer and resumes from saved state"
  def start_agent(id) do
    case :ets.lookup(@ets_table, id) do
      [] ->
        {:error, "Agent not found"}

      [{^id, summary}] ->
        # The REAL check is whether a GenServer is actually running. ETS
        # status can be stale after a crash (still :idle even though the
        # process is gone). Registry is authoritative about liveness.
        case agent_alive?(id) do
          true ->
            {:error, "Agent already running"}

          false ->
            do_start_agent(id, summary)
        end
    end
  end

  defp agent_alive?(id) do
    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
      [{pid, _}] -> Process.alive?(pid)
      _ -> false
    end
  end

  defp do_start_agent(id, summary) do
    opts =
      [
        id: id,
        name: summary.name,
        working_dir: summary[:working_dir],
        bind_mount: summary[:bind_mount],
        workspace_id: summary[:workspace_id],
        volume: summary[:volume],
        resume: true
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    supervisor =
      if summary[:workspace_id] do
        Loopyard.WorkspaceGroup.agent_sup_name(summary[:workspace_id])
      else
        Loopyard.AgentSupervisor
      end

    case DynamicSupervisor.start_child(supervisor, {Loopyard.ChatAgent, opts}) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Remove a stopped/crashed agent — transitions to :destroying, cleans up Docker, then removes from sidebar"
  def remove_agent(id) do
    # Transition to :destroying via the StateMachine so we reject the
    # "remove → restart → remove again" race: once an agent is
    # :destroying, a second remove_agent call is a no-op instead of
    # re-broadcasting and re-entering cleanup.
    case :ets.lookup(@ets_table, id) do
      [{^id, %{status: :destroying}}] ->
        :ok

      [{^id, summary}] ->
        case Loopyard.ChatAgent.StateMachine.transition(summary.status, :destroying) do
          {:ok, :destroying} ->
            destroying = %{summary | status: :destroying}
            :ets.insert(@ets_table, {id, destroying})
            Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :destroying})

          {:error, reason} ->
            Loopyard.EventLog.warning(
              "agent:#{summary[:name] || id}",
              "remove_agent: invalid status transition #{inspect(reason)} — " <>
                "proceeding with cleanup anyway"
            )

            destroying = %{summary | status: :destroying}
            :ets.insert(@ets_table, {id, destroying})
            Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :destroying})
        end

      [] ->
        :ok
    end

    # Persist removal to agent log so it's not replayed on restart.
    # Wrap the append — disk failure here shouldn't crash remove_agent
    # (caller is typically a LiveView process the user is interacting
    # with). ETS deletion below is authoritative for runtime state;
    # the log record is belt-and-suspenders for replay.
    case :ets.lookup(@ets_table, id) do
      [{^id, summary}] ->
        ws_id = summary[:workspace_id]

        if ws_id do
          path = Persistence.log_path(ws_id)

          try do
            AgentLog.append({:agent_removed, id}, log_path: path, version: 1)
          rescue
            e ->
              Loopyard.EventLog.warning(
                "agent:#{summary[:name] || id}",
                "remove_agent: failed to persist :agent_removed record: #{Exception.message(e)}. " <>
                  "The agent will be removed from ETS; if this BEAM restarts before the log is " <>
                  "writable again, the agent will be replayed back into ETS on boot."
              )
          catch
            kind, reason ->
              Loopyard.EventLog.warning(
                "agent:#{summary[:name] || id}",
                "remove_agent: log append #{kind}: #{inspect(reason)}"
              )
          end
        end

      [] ->
        :ok
    end

    # Hard-stop the live GenServer FIRST so it can't restart and can't re-insert
    # itself into ETS. Deleting the ETS row alone left the process running, and
    # its next summary write resurrected the row — the "removed agent came back"
    # bug. Terminate via the DynamicSupervisor so OTP won't restart it.
    terminate_process(id)

    # Revoke this agent's outstanding MCP bridge tokens — the agent is gone, so
    # a leaked token must stop working (issue #81). This is a definitive
    # removal, not a transient restart (restart re-mints a token), so bumping
    # the epoch here can't strand a live agent.
    Loopyard.MCP.Token.revoke(id)

    # Remove from sidebar
    :ets.delete(@ets_table, id)
    Events.ChatAgent.publish(%Events.ChatAgent.Removed{id: id})
  end

  # Terminate an agent's process so a removed agent stays removed. Best-effort:
  # via the workspace's agent supervisor (no restart) when we know the workspace,
  # else a direct stop; never raises.
  defp terminate_process(id) do
    ws_id =
      case :ets.lookup(@ets_table, id) do
        [{^id, summary}] -> summary[:workspace_id]
        _ -> nil
      end

    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
      [{pid, _}] when is_binary(ws_id) ->
        DynamicSupervisor.terminate_child(Loopyard.WorkspaceGroup.agent_sup_name(ws_id), pid)

      [{pid, _}] ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 3_000)

      [] ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Register an agent as booting in ETS so all viewers can see it"
  def register_booting(id, name, working_dir, opts \\ []) do
    # Go through summary/1 so the booting entry carries every field
    # summary exposes — tokens (0.0), cost, model (nil), turns, etc.
    # Same reason as init_resume: the UI reads these unconditionally
    # and a partial map would surface as KeyError or zeroed values
    # that look real.
    now = DateTime.utc_now()

    # Populate workspace_id so the booting entry is visible to the
    # sidebar filter (which keys off workspace_id, not working_dir).
    # Without this, booting agents silently disappear from the
    # sidebar until their session comes up and overwrites the ETS row
    # with a fully-populated summary.
    workspace_id =
      Keyword.get(opts, :workspace_id) ||
        Loopyard.Workspace.workspace_id(working_dir)

    stub = %Loopyard.ChatAgent{
      id: id,
      name: name,
      working_dir: working_dir,
      workspace_id: workspace_id,
      workstation_identity:
        Keyword.get(opts, :workstation_identity) || Loopyard.Workstation.current(),
      service_name: Keyword.get(opts, :service_name),
      started_at: now,
      started_by: "browser",
      last_activity_at: now,
      status: :booting
    }

    summary = stub |> Loopyard.ChatAgent.summary() |> Map.put(:boot_status, "Initializing...")

    :ets.insert(@ets_table, {id, summary})
    Events.ChatAgent.publish(%Events.ChatAgent.Booting{summary: summary})
    summary
  end

  @doc "Update boot status in ETS and broadcast to all viewers"
  def update_boot_status(id, status_text) do
    case :ets.lookup(@ets_table, id) do
      [{^id, summary}] ->
        updated = %{summary | boot_status: status_text, last_activity_at: DateTime.utc_now()}
        :ets.insert(@ets_table, {id, updated})
        Events.ChatAgent.publish(%Events.ChatAgent.BootStatus{id: id, status: status_text})

      [] ->
        :ok
    end
  end

  @doc "Mark a booting agent as failed and remove it"
  def boot_failed(id, reason) do
    :ets.delete(@ets_table, id)
    Events.ChatAgent.publish(%Events.ChatAgent.BootFailed{id: id, reason: reason})
  end

  @doc """
  Every agent's persisted summary straight from ETS — NO GenServer round-trips.

  Use this when you only need the durable summary fields (id, name, status,
  workspace_id, working_dir, bind_mount) and not live per-turn state. Unlike
  `list_agents/0`, it never issues one `get_state` call per live agent, so it
  stays O(ETS) even when agents are busy/wedged — safe on a mount path. Callers
  that render live status stay fresh via ChatAgent PubSub, not this read.
  """
  def list_agent_summaries do
    :ets.tab2list(@ets_table) |> Enum.map(fn {_id, summary} -> summary end)
  end

  @doc "List every agent's current summary, freshening live ones from their GenServer."
  def list_agents do
    :ets.tab2list(@ets_table)
    |> Enum.map(fn {_id, summary} -> refresh_summary(summary) end)
    |> sort_by_recency()
  end

  @doc """
  Agent summaries for ONE workspace, refreshed from live GenServers.

  Filters the ETS table by `workspace_id` FIRST — a cheap map compare — so the
  cost is proportional to THIS workspace's agents, not the global table. That
  table can hold thousands of rows on a long-lived server (or across a full
  test suite), and `list_agents/0` pays a `Registry.lookup` + `get_state` for
  every one; scoping first means only the workspace's live agents are touched.
  This is the mount-path query — it must stay cheap.
  """
  def list_agents_for_workspace(workspace_id) do
    :ets.tab2list(@ets_table)
    |> Enum.filter(fn {_id, s} -> is_map(s) and s[:workspace_id] == workspace_id end)
    |> Enum.map(fn {_id, summary} -> refresh_summary(summary) end)
    |> sort_by_recency()
  end

  @doc """
  Cheap yes/no: is any agent for this workspace already in ETS? Pure map
  compares over the raw table, no `Registry.lookup`/`get_state` — safe to call
  on the mount hot path (unlike `list_agents/0`).
  """
  def workspace_loaded?(workspace_id) do
    :ets.foldl(
      fn {_id, s}, acc -> acc or (is_map(s) and s[:workspace_id] == workspace_id) end,
      false,
      @ets_table
    )
  end

  # Refresh one ETS summary from its live GenServer (if any).
  defp refresh_summary(summary) do
    case Registry.lookup(Loopyard.ChatAgentRegistry, summary.id) do
      [{pid, _}] ->
        try do
          # 500ms timeout matches get_state/1 — a wedged agent shouldn't block
          # the whole call while the UI waits. ETS summary is the fallback.
          GenServer.call(pid, :get_state, 500)
        catch
          :exit, _ -> summary
        end

      [] ->
        # No live GenServer. If the summary claims :booting and it's been sitting
        # there longer than @stuck_booting_seconds, the boot task almost
        # certainly died without running its rescue/catch clauses (TaskSupervisor
        # shutdown, OS kill, etc). Present it as :crashed so the user sees a real
        # action (Start/Remove) instead of a perpetual spinner.
        if stuck_booting?(summary), do: %{summary | status: :crashed}, else: summary
    end
  end

  # Newest first. Agents without a started_at (test-seeded ETS rows, half-
  # populated boot state) would crash DateTime.compare/2 — treat missing
  # timestamps as "oldest" so the sort is total and safe.
  defp sort_by_recency(agents) do
    Enum.sort_by(agents, & &1[:started_at], fn
      nil, nil -> true
      nil, _ -> false
      _, nil -> true
      a, b -> DateTime.compare(a, b) != :lt
    end)
  end

  defp stuck_booting?(%{status: :booting, started_at: %DateTime{} = t}) do
    DateTime.diff(DateTime.utc_now(), t, :second) > @stuck_booting_seconds
  end

  defp stuck_booting?(_), do: false
end
