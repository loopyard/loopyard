defmodule BoomLooper.ChatAgent.RestartController do
  @moduledoc """
  Move #10 Quarantine (plans/coordination-hardening.md).

  Owns every respawn decision for ChatAgents under a single
  workspace. Stock `DynamicSupervisor` supervises the actual agents
  with `restart: :temporary` — OTP never auto-restarts anything.
  When a ChatAgent crashes, this controller gets the `:DOWN` and
  decides synchronously whether to respawn or quarantine.

  This is option (a) from the design interview: deterministic, no
  race between supervisor auto-restart and quarantine decision. The
  restart decision happens in one place, in one process, in one
  synchronous step. Crash #5 triggers quarantine BEFORE crash #6
  can ever happen.

  ## Threshold

  Default: 5 crashes within 60 seconds quarantines the agent.
  Configurable via Application env for tests:

      Application.put_env(:boom_looper, :quarantine_threshold, {5, 60_000})

  The threshold matches `ChatAgent.@max_consecutive_crashes` so the
  existing backoff semantics and the quarantine trigger agree.

  ## Quarantine state

  Lives in the agent's ETS summary as a `:quarantined` boolean plus
  a `:quarantine_reason` field. Persists across server restarts via
  the agent log. A quarantined agent:

    * Is not auto-respawned by the controller
    * Is skipped by `ServiceManager`'s log-replay respawn
    * Shows as `:quarantined` in `agent_display_status/1`
    * Must be released manually via `release/1` or the UI

  ## Release

  Operators release a quarantined agent from `/system/quarantine`
  (one click per agent) or via `mix boom.rpc`:

      mix boom.rpc 'BoomLooper.ChatAgent.RestartController.release("agent-id")'

  Release clears the flag and respawns the agent via the normal
  start_agent path.
  """

  use GenServer
  require Logger

  @default_threshold_count 5
  @default_threshold_window_ms 60_000

  # Telemetry event fired when an actor enters quarantine. Paired
  # with `[:boom_looper, :quarantine, :released]` on release.
  @telemetry_triggered [:boom_looper, :quarantine, :triggered]
  @telemetry_released [:boom_looper, :quarantine, :released]

  # ── Public API ──

  def start_link(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    GenServer.start_link(__MODULE__, opts, name: via(workspace_id))
  end

  @doc """
  Start a ChatAgent under this workspace. Refuses if the agent is
  already quarantined — operator must `release/1` first.

  Returns `{:ok, pid}` | `{:error, :quarantined}` |
  `{:error, :workspace_not_running}` | `{:error, reason}`.
  """
  def start_agent(workspace_id, agent_opts) do
    id = Keyword.fetch!(agent_opts, :id)

    case quarantined?(id) do
      true -> {:error, :quarantined}
      false -> do_start_agent(workspace_id, agent_opts)
    end
  end

  @doc "Release a quarantined agent. Idempotent."
  def release(agent_id) do
    case :ets.lookup(:chat_agents, agent_id) do
      [{^agent_id, summary}] ->
        cleared = Map.drop(summary, [:quarantined, :quarantine_reason, :quarantine_crashed_at])
        :ets.insert(:chat_agents, {agent_id, cleared})

        :telemetry.execute(@telemetry_released, %{count: 1}, %{agent_id: agent_id})

        Phoenix.PubSub.broadcast(
          BoomLooper.PubSub,
          "chat_agents",
          {:chat_agent_released, agent_id}
        )

        BoomLooper.EventLog.info(
          "quarantine:#{agent_id}",
          "Released from quarantine"
        )

        :ok

      [] ->
        :ok
    end
  end

  @doc """
  Check whether an agent is currently quarantined. Reads the ETS
  summary directly — zero controller hops.
  """
  def quarantined?(agent_id) do
    case :ets.lookup(:chat_agents, agent_id) do
      [{^agent_id, %{quarantined: true}}] -> true
      _ -> false
    end
  end

  @doc """
  List every quarantined agent across all workspaces, with reason
  and when it was quarantined. For `/system/quarantine`.
  """
  def list_quarantined do
    :ets.tab2list(:chat_agents)
    |> Enum.filter(fn {_, summary} -> Map.get(summary, :quarantined) == true end)
    |> Enum.map(fn {id, summary} ->
      %{
        id: id,
        name: Map.get(summary, :name, "unknown"),
        workspace_id: Map.get(summary, :workspace_id),
        reason: Map.get(summary, :quarantine_reason),
        crashed_at: Map.get(summary, :quarantine_crashed_at)
      }
    end)
  end

  @doc false
  # Used by WorkspaceGroup.start_agent/2 as the entry point. Public
  # so the supervisor can reach this GenServer without a naming hack.
  def registered_name(workspace_id), do: via(workspace_id)

  # ── GenServer ──

  @impl true
  def init(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)

    state = %{
      workspace_id: workspace_id,
      # Map: agent_id → [crashed_at_timestamps]. Cleared on successful
      # respawn (clean run), rolled forward on each crash.
      crash_history: %{},
      # Map: monitor_ref → {agent_id, agent_opts}. Lets us re-spawn
      # from the original opts when a ChatAgent crashes.
      monitors: %{},
      # Map: agent_id → agent_opts. Keeps the opts available even
      # if multiple monitors are in flight.
      agent_opts: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:start_agent, agent_opts}, _from, state) do
    workspace_id = state.workspace_id
    id = Keyword.fetch!(agent_opts, :id)

    # The actual GenServer start goes through the DynamicSupervisor
    # so OTP owns child spec, shutdown, and link management. We just
    # monitor the pid that comes back.
    sup_name = BoomLooper.WorkspaceGroup.agent_sup_name(workspace_id)

    case DynamicSupervisor.start_child(sup_name, {BoomLooper.ChatAgent, agent_opts}) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        state =
          state
          |> put_in([:monitors, ref], {id, agent_opts})
          |> put_in([:agent_opts, id], agent_opts)

        {:reply, {:ok, pid}, state}

      {:error, reason} = err ->
        Logger.warning("[RestartController] #{id} start failed: #{inspect(reason)}")
        {:reply, err, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        # Not one of ours — probably leftover from a previous start
        {:noreply, state}

      {{agent_id, agent_opts}, monitors} ->
        state = %{state | monitors: monitors}
        handle_agent_down(state, agent_id, agent_opts, reason)
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Core: respawn or quarantine ──

  # Normal shutdown (stop/remove/destroy) — no respawn, no crash
  # counted. Clean up tracking state.
  defp handle_agent_down(state, agent_id, _opts, :normal) do
    state = update_in(state.agent_opts, &Map.delete(&1, agent_id))
    state = update_in(state.crash_history, &Map.delete(&1, agent_id))
    {:noreply, state}
  end

  defp handle_agent_down(state, agent_id, _opts, :shutdown) do
    # Supervisor-initiated shutdown (e.g. workspace tearing down).
    # Treat same as :normal.
    state = update_in(state.agent_opts, &Map.delete(&1, agent_id))
    state = update_in(state.crash_history, &Map.delete(&1, agent_id))
    {:noreply, state}
  end

  defp handle_agent_down(state, agent_id, _opts, {:shutdown, _}) do
    state = update_in(state.agent_opts, &Map.delete(&1, agent_id))
    state = update_in(state.crash_history, &Map.delete(&1, agent_id))
    {:noreply, state}
  end

  # Abnormal exit — count the crash, decide whether to respawn.
  defp handle_agent_down(state, agent_id, agent_opts, reason) do
    now = System.monotonic_time(:millisecond)
    {count, window_ms} = threshold()

    history =
      state.crash_history
      |> Map.get(agent_id, [])
      |> Enum.filter(&(now - &1 <= window_ms))

    history = [now | history]
    state = put_in(state.crash_history[agent_id], history)

    Logger.warning(
      "[RestartController] #{agent_id} crashed (#{length(history)}/#{count} in window): " <>
        inspect(reason, limit: 50)
    )

    if length(history) >= count do
      quarantine(state, agent_id, reason)
    else
      respawn(state, agent_id, agent_opts)
    end
  end

  defp quarantine(state, agent_id, reason) do
    now = DateTime.utc_now()

    # Mark the agent quarantined in ETS so (1) the UI renders it as
    # quarantined, (2) `quarantined?/1` is a pure ETS read, (3) the
    # summary persists via the normal agent log path.
    case :ets.lookup(:chat_agents, agent_id) do
      [{^agent_id, summary}] ->
        updated =
          Map.merge(summary, %{
            status: :crashed,
            quarantined: true,
            quarantine_reason: inspect(reason, limit: 100),
            quarantine_crashed_at: now
          })

        :ets.insert(:chat_agents, {agent_id, updated})

        Phoenix.PubSub.broadcast(
          BoomLooper.PubSub,
          "chat_agents",
          {:chat_agent_quarantined, agent_id, updated}
        )

      [] ->
        :ok
    end

    :telemetry.execute(@telemetry_triggered, %{crash_count: elem(threshold(), 0)}, %{
      agent_id: agent_id,
      reason: inspect(reason, limit: 100)
    })

    BoomLooper.EventLog.error(
      "quarantine:#{agent_id}",
      "Quarantined after #{elem(threshold(), 0)} crashes in #{elem(threshold(), 1)}ms: " <>
        inspect(reason, limit: 100)
    )

    # Clear tracking — if operator releases, we start fresh.
    state = update_in(state.crash_history, &Map.delete(&1, agent_id))
    state = update_in(state.agent_opts, &Map.delete(&1, agent_id))
    {:noreply, state}
  end

  defp respawn(state, agent_id, agent_opts) do
    # Respawn with the same opts. The ChatAgent GenServer handles
    # resume-from-ETS via `resume: true` already; we pass opts
    # verbatim so whatever the original caller set carries through.
    workspace_id = state.workspace_id
    sup_name = BoomLooper.WorkspaceGroup.agent_sup_name(workspace_id)

    # Add resume: true so the respawned agent picks up existing state.
    opts = Keyword.put(agent_opts, :resume, true)

    case DynamicSupervisor.start_child(sup_name, {BoomLooper.ChatAgent, opts}) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        state =
          state
          |> put_in([:monitors, ref], {agent_id, opts})
          |> put_in([:agent_opts, agent_id], opts)

        {:noreply, state}

      {:error, reason} ->
        # Couldn't respawn. Don't loop forever trying — treat as
        # quarantine so the operator sees it.
        Logger.error(
          "[RestartController] #{agent_id} respawn failed: #{inspect(reason)}. Quarantining."
        )

        quarantine(state, agent_id, {:respawn_failed, reason})
    end
  end

  # ── Internals ──

  defp do_start_agent(workspace_id, agent_opts) do
    case Registry.lookup(
           BoomLooper.ChatAgent.RestartControllerRegistry,
           workspace_id
         ) do
      [{pid, _}] ->
        GenServer.call(pid, {:start_agent, agent_opts}, 10_000)

      [] ->
        {:error, :workspace_not_running}
    end
  end

  defp threshold do
    Application.get_env(
      :boom_looper,
      :quarantine_threshold,
      {@default_threshold_count, @default_threshold_window_ms}
    )
  end

  defp via(workspace_id) do
    {:via, Registry, {BoomLooper.ChatAgent.RestartControllerRegistry, workspace_id}}
  end
end
