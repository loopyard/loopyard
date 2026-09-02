defmodule Loopyard.ChangeCounts do
  @moduledoc """
  Event-driven cache of per-workspace changed-file counts (the overview's
  "did anything change?" signal).

  `git status` is a container/host shell-out, so overview surfaces must NEVER
  compute it at render time (the /workspaces mount budget forbids shell-outs).
  Instead this GenServer recomputes counts asynchronously on the moments
  changes actually move, and stashes them in the `:ws_change_counts` ETS table
  (owned by `StateKeeper`) for `Loopyard.WorkspaceTree` to read for free:

    * an agent's `StatusChanged` → `:idle` (a turn just ended — the same
      trigger the workspace right-pane uses for its Changes hero);
    * a slow periodic sweep (~5 min) for drift (human edits via sync, etc).

  Workspaces without a running work container are SKIPPED (nothing to ask;
  the UI shows no badge — "unknown", not a misleading 0). Recomputes are
  deduped per workspace while one is in flight. On an actual count change the
  new value is published via `Loopyard.Events.ChangeCounts` so open trees
  patch live.

  Config-gated (`:change_counts_enabled?`, off in test) — like the send-path
  wake, this boots real git work against real containers.
  """
  use GenServer
  require Logger

  alias Loopyard.Events

  @table :ws_change_counts
  @sweep_ms 5 * 60 * 1000

  # --- Read API (used by WorkspaceTree — must stay ETS-only) ---

  @doc """
  Cached uncommitted diff for a workspace as LINES `%{added: n, removed: m}`,
  or nil when unknown (no running work container yet / never computed).
  """
  @spec get(String.t()) :: %{added: non_neg_integer(), removed: non_neg_integer()} | nil
  def get(workspace_id) when is_binary(workspace_id) do
    case :ets.lookup(@table, workspace_id) do
      [{^workspace_id, count, _computed_at}] -> count
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def get(_), do: nil

  @doc "Ask for a recompute of one workspace (async, deduped). Safe to call from anywhere."
  def refresh(workspace_id) when is_binary(workspace_id) do
    if enabled?(), do: GenServer.cast(__MODULE__, {:refresh, workspace_id}), else: :ok
  end

  # --- Lifecycle ---

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if enabled?() do
      Events.ChatAgent.subscribe()
      Process.send_after(self(), :sweep, @sweep_ms)
    end

    {:ok, %{in_flight: MapSet.new()}}
  end

  # Agent finished a turn → its workspace's tree may have changed.
  @impl true
  def handle_info(%Events.ChatAgent.StatusChanged{id: agent_id, status: :idle}, state) do
    ws_id = workspace_of(agent_id)
    {:noreply, maybe_recompute(state, ws_id)}
  end

  def handle_info(%Events.ChatAgent.StatusChanged{}, state), do: {:noreply, state}

  # Boot replay resumes every persisted agent — expected topic traffic, not
  # unknown messages (the catchall was dumping each agent's ENTIRE message
  # history into the log as a warning, once per agent, on every server boot).
  # A resumed agent may have pending work → treat like a turn boundary.
  def handle_info(%Events.ChatAgent.Resumed{summary: %{id: agent_id}}, state) do
    {:noreply, maybe_recompute(state, workspace_of(agent_id))}
  end

  def handle_info(%Events.ChatAgent.Resumed{}, state), do: {:noreply, state}

  # Same shape, same reason as Resumed above — a newly started agent is a turn
  # boundary for its workspace, and the catchall was dumping its ENTIRE message
  # history into the log as a warning on every boot. (Resumed was fixed for
  # this; Started has the identical signature and was missed.)
  def handle_info(%Events.ChatAgent.Started{summary: %{id: agent_id}}, state) do
    {:noreply, maybe_recompute(state, workspace_of(agent_id))}
  end

  def handle_info(%Events.ChatAgent.Started{}, state), do: {:noreply, state}

  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, @sweep_ms)

    state =
      Loopyard.ProjectRegistry.list_projects()
      |> Enum.flat_map(&Loopyard.WorkspaceRegistry.list_workspaces(&1.id))
      |> Enum.reduce(state, fn ws, acc -> maybe_recompute(acc, ws[:id]) end)

    {:noreply, state}
  rescue
    _ ->
      Process.send_after(self(), :sweep, @sweep_ms)
      {:noreply, state}
  end

  def handle_info({:recomputed, ws_id}, state),
    do: {:noreply, %{state | in_flight: MapSet.delete(state.in_flight, ws_id)}}

  # Catchall (project rule): unknown messages never crash the GenServer.
  def handle_info(msg, state) do
    Logger.warning("[ChangeCounts] unhandled info: #{inspect(msg, limit: 100)}")
    :telemetry.execute([:loopyard, :actor, :unknown_message], %{count: 1}, %{actor: __MODULE__})
    {:noreply, state}
  end

  @impl true
  def handle_cast({:refresh, ws_id}, state), do: {:noreply, maybe_recompute(state, ws_id)}

  def handle_cast(msg, state) do
    Logger.warning("[ChangeCounts] unhandled cast: #{inspect(msg, limit: 100)}")
    :telemetry.execute([:loopyard, :actor, :unknown_message], %{count: 1}, %{actor: __MODULE__})
    {:noreply, state}
  end

  @impl true
  def handle_call(msg, _from, state) do
    Logger.warning("[ChangeCounts] unhandled call: #{inspect(msg, limit: 100)}")
    :telemetry.execute([:loopyard, :actor, :unknown_message], %{count: 1}, %{actor: __MODULE__})
    {:reply, {:error, :unknown_call}, state}
  end

  # --- Recompute machinery ---

  defp maybe_recompute(state, nil), do: state

  defp maybe_recompute(state, ws_id) do
    cond do
      MapSet.member?(state.in_flight, ws_id) ->
        state

      not work_container_running?(ws_id) ->
        state

      true ->
        me = self()

        Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
          recompute(ws_id)
          send(me, {:recomputed, ws_id})
        end)

        %{state | in_flight: MapSet.put(state.in_flight, ws_id)}
    end
  end

  defp recompute(ws_id) do
    with ws when is_map(ws) <- Loopyard.WorkspaceRegistry.get_workspace(ws_id),
         project when is_map(project) <-
           Loopyard.ProjectRegistry.get_project(ws[:project_id]),
         adapter <- Loopyard.Source.for_project(project),
         true <- Loopyard.Source.supports_git?(adapter),
         {:ok, %{added: added, removed: removed}} <- adapter.git_diff_stat(project, ws) do
      put(ws_id, %{added: added, removed: removed})
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  # Store + publish only when the value MOVED — no rebuild storms for no-ops. The
  # cached value is now `%{added, removed}` (line +/-); the event still carries a
  # scalar `count` (added+removed) since subscribers just trigger a tree reload.
  defp put(ws_id, %{added: added, removed: removed} = changes) do
    prev =
      case :ets.lookup(@table, ws_id) do
        [{^ws_id, c, _}] -> c
        _ -> nil
      end

    :ets.insert(@table, {ws_id, changes, System.system_time(:second)})

    if changes != prev do
      Events.ChangeCounts.publish(%Events.ChangeCounts.Updated{
        workspace_id: ws_id,
        count: added + removed
      })
    end

    :ok
  end

  # No running work container → nothing to ask; leave the count unknown.
  defp work_container_running?(ws_id) do
    Loopyard.Docker.Observer.containers_for(ws_id)
    |> Enum.any?(&Map.get(&1, :running, false))
  rescue
    _ -> false
  end

  defp workspace_of(agent_id) do
    case Loopyard.ChatAgent.get_state(agent_id) do
      %{workspace_id: ws_id} when is_binary(ws_id) -> ws_id
      _ -> nil
    end
  end

  defp enabled?, do: Application.get_env(:loopyard, :change_counts_enabled?, true)
end
