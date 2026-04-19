defmodule BoomLooper.Source.Local.SyncMonitor do
  @moduledoc """
  Supervised per-workspace GenServer that owns the mutagen sync session for
  one Local workspace. One child of `BoomLooper.WorkspaceGroup` per Local
  workspace.

  The session is long-running external state: the mutagen daemon can die,
  the session can wedge on conflicts, or the workspace container can
  rebuild. This GenServer monitors the session via periodic polling and
  reconciles — restarting the session, pausing on container-down, and
  broadcasting state changes to the LiveView layer via PubSub.

  ## Robustness properties

  - **Non-blocking.** All shell-outs (to mutagen, to docker) run inside
    `Task`s spawned via `Task.Supervisor.async_nolink`. The GenServer loop
    is never blocked on external I/O — `status/1` calls always return
    promptly.

  - **Exponential backoff.** If the session repeatedly fails to start or
    the daemon is unreachable, poll intervals back off (5s → 10s → 20s →
    capped at 60s). A successful `:running` transition resets the backoff.

  - **Session survives supervisor restarts.** On `terminate/2`, mutagen
    sessions are *not* torn down by default — adoption happens on the next
    `init/1`. Call `prepare_for_removal/1` before stopping the process if
    you really want the session gone (e.g. workspace deletion).

  ## Public API

      SyncMonitor.status(workspace_id)
      SyncMonitor.restart(workspace_id)
      SyncMonitor.pause(workspace_id)
      SyncMonitor.resume(workspace_id)
      SyncMonitor.container_up(workspace_id)
      SyncMonitor.container_down(workspace_id)
      SyncMonitor.prepare_for_removal(workspace_id)

  Broadcasts `{:source_sync, workspace_id, status_map}` on PubSub topic
  `"source_sync:<workspace_id>"` on every state transition.
  """
  use GenServer, restart: :transient

  require Logger

  alias BoomLooper.Source.Local.{Mutagen, Worktree}

  @registry BoomLooper.SyncMonitorRegistry

  @base_poll_interval 5_000
  @max_poll_interval 60_000
  @ready_probe_attempts 5
  @ready_probe_delay 200

  defstruct [
    :workspace_id,
    :worktree_path,
    :container_name,
    :probe_task,
    status: :starting,
    last_error: nil,
    last_checked_at: nil,
    consecutive_errors: 0,
    removing: false,
    sync_details: nil
  ]

  # --- Public API ---

  def start_link(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    GenServer.start_link(__MODULE__, opts, name: via(workspace_id))
  end

  @doc "Look up the SyncMonitor pid for a workspace, if any."
  def whereis(workspace_id) do
    case Registry.lookup(@registry, workspace_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Return the current status map for a workspace's sync session."
  def status(workspace_id) do
    call(workspace_id, :status, %{
      status: :stopped,
      last_error: nil,
      last_checked_at: nil
    })
  end

  @doc "Force a restart of the sync session. Terminates the old, creates a new."
  def restart(workspace_id), do: cast(workspace_id, :restart)

  @doc "Pause the sync session."
  def pause(workspace_id), do: cast(workspace_id, :pause)

  @doc "Resume a paused sync session."
  def resume(workspace_id), do: cast(workspace_id, :resume)

  @doc "Signal that the workspace container came up. Starts the session."
  def container_up(workspace_id), do: cast(workspace_id, :container_up)

  @doc "Signal that the workspace container went down. Pauses the session."
  def container_down(workspace_id), do: cast(workspace_id, :container_down)

  @doc """
  Mark the monitor as "about to be removed" so that `terminate/2` actually
  tears down the mutagen session. Call this before killing the process
  during workspace removal.
  """
  def prepare_for_removal(workspace_id), do: cast(workspace_id, :prepare_for_removal)

  @doc """
  PubSub topic for status updates on a given workspace.

  Delegates to `BoomLooper.Events.SourceSync.topic/1` — the topic name is
  owned by the publisher module now, this alias stays for older callers.
  """
  def topic(workspace_id), do: BoomLooper.Events.SourceSync.topic(workspace_id)

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    worktree_path = Keyword.get(opts, :worktree_path) || Worktree.path_for(workspace_id)
    container_name = Keyword.get(opts, :container_name) || default_container_name(workspace_id)

    state = %__MODULE__{
      workspace_id: workspace_id,
      worktree_path: worktree_path,
      container_name: container_name
    }

    # First probe runs asynchronously so init stays instant. The probe
    # adopts an existing session via Mutagen.session_status, or creates
    # a new one if the container is up and the session is missing.
    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_map(state), state}
  end

  @impl true
  def handle_cast(:restart, state) do
    # User-initiated restart: terminate old session, transition to
    # :starting (guarantees a broadcast even if the probe ends up in the
    # same state), then probe to create a new session.
    cancel_probe(state)
    Mutagen.terminate_sync(state.workspace_id)
    state = %{state | consecutive_errors: 0}
    state = transition(state, :starting, nil)
    {:noreply, start_probe(state)}
  end

  def handle_cast(:pause, state) do
    case Mutagen.pause_sync(state.workspace_id) do
      :ok -> {:noreply, transition(state, :paused, nil)}
      {:error, reason} -> {:noreply, transition(state, :errored, reason)}
    end
  end

  def handle_cast(:resume, state) do
    case Mutagen.resume_sync(state.workspace_id) do
      :ok -> {:noreply, transition(state, :running, nil)}
      {:error, reason} -> {:noreply, transition(state, :errored, reason)}
    end
  end

  def handle_cast(:container_up, state) do
    cancel_probe(state)
    {:noreply, start_probe(state)}
  end

  def handle_cast(:container_down, state) do
    cancel_probe(state)

    case Mutagen.pause_sync(state.workspace_id) do
      :ok -> {:noreply, transition(state, :paused, nil)}
      _ -> {:noreply, transition(state, :stopped, nil)}
    end
  end

  def handle_cast(:prepare_for_removal, state) do
    {:noreply, %{state | removing: true}}
  end

  @impl true
  def handle_info(:tick, state) do
    # Normal periodic probe. If a probe is already in flight, skip this
    # tick — we don't want two concurrent tasks racing.
    if state.probe_task do
      schedule_next_poll(state)
      {:noreply, state}
    else
      {:noreply, start_probe(state)}
    end
  end

  # Task result — probe succeeded or failed.
  def handle_info({ref, result}, %{probe_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | probe_task: nil}
    state = apply_probe_result(state, result)
    schedule_next_poll(state)
    {:noreply, state}
  end

  # Task crashed — treat as an error and back off.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{probe_task: %Task{ref: ref}} = state) do
    state = %{state | probe_task: nil}
    state = transition(state, :errored, "probe crashed: #{inspect(reason)}", bump_errors: true)
    schedule_next_poll(state)
    {:noreply, state}
  end

  # Stale task result from a cancelled probe — ignore.
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Default: leave the session alone so a supervisor restart (hot reload,
    # `:one_for_all` restart in WorkspaceGroup) doesn't churn it. The next
    # init/1 will adopt the existing session by name. Only tear it down if
    # the caller explicitly asked for removal.
    if state.removing do
      Mutagen.terminate_sync(state.workspace_id)
    end

    :ok
  end

  # --- Probe machinery ---

  # Launch a probe task that runs mutagen/docker calls off the GenServer
  # loop. Result comes back as a plain message to `handle_info({ref, ...})`.
  defp start_probe(state) do
    parent = self()
    workspace_id = state.workspace_id
    container_name = state.container_name
    worktree_path = state.worktree_path

    task =
      Task.Supervisor.async_nolink(BoomLooper.TaskSupervisor, fn ->
        do_probe(workspace_id, worktree_path, container_name)
      end)

    # Narrow the wrapper so older Erlang doesn't mind nil parent use —
    # async_nolink already links via the supervisor, so we don't need to
    # reference `parent` further.
    _ = parent

    %{state | probe_task: task}
  end

  defp cancel_probe(%{probe_task: nil} = _state), do: :ok

  defp cancel_probe(%{probe_task: %Task{} = task}) do
    # Best-effort shutdown — we don't wait forever for a blocked shell.
    _ = Task.Supervisor.terminate_child(BoomLooper.TaskSupervisor, task.pid)
    :ok
  end

  # Runs inside the probe task (not the GenServer). Must not touch state.
  defp do_probe(workspace_id, worktree_path, container_name) do
    case Mutagen.session_status(workspace_id) do
      {:rich, :running, details} ->
        {:ok, :running, details}

      {:rich, :paused, details} ->
        {:ok, :paused, details}

      {:rich, :errored, _details} ->
        {:error, :session_errored}

      :running ->
        {:ok, :running}

      :paused ->
        {:ok, :paused}

      :errored ->
        {:error, :session_errored}

      status when status in [:unknown, :missing] ->
        create_session(workspace_id, worktree_path, container_name)
    end
  end

  # Tiny DSL for "try to bring a session up cleanly": wait for exec-ready,
  # then ask mutagen to create the session.
  defp create_session(workspace_id, worktree_path, container_name) do
    with :ok <- ensure_worktree(worktree_path),
         :ok <- wait_for_container_ready(container_name),
         :ok <- Mutagen.start_sync(workspace_id, worktree_path, container_name) do
      {:ok, :running}
    end
  end

  defp ensure_worktree(path) do
    if File.dir?(path), do: :ok, else: {:error, {:worktree_missing, path}}
  end

  defp wait_for_container_ready(container, attempts \\ @ready_probe_attempts)

  defp wait_for_container_ready(_container, 0), do: {:error, :container_not_ready}

  defp wait_for_container_ready(container, attempts) do
    case container_ready_check(container) do
      {:ok, _} ->
        :ok

      :ok ->
        :ok

      {:error, _} ->
        Process.sleep(@ready_probe_delay)
        wait_for_container_ready(container, attempts - 1)
    end
  end

  # Hook for tests to stub out the docker exec probe. Defaults to the real
  # thing in production.
  defp container_ready_check(container) do
    case Application.get_env(:boom_looper, :container_ready_check) do
      nil -> BoomLooper.Docker.exec_in(container, "true")
      fun when is_function(fun, 1) -> fun.(container)
    end
  end

  # --- Probe result → state transitions ---

  defp apply_probe_result(state, {:ok, :running, details}) do
    %{state | consecutive_errors: 0, sync_details: details}
    |> transition(:running, nil)
  end

  defp apply_probe_result(state, {:ok, :running}) do
    %{state | consecutive_errors: 0}
    |> transition(:running, nil)
  end

  defp apply_probe_result(state, {:ok, :paused, details}) do
    %{state | sync_details: details}
    |> transition(:paused, nil)
  end

  defp apply_probe_result(state, {:ok, :paused}) do
    transition(state, :paused, nil)
  end

  defp apply_probe_result(state, {:error, {:worktree_missing, path}}) do
    transition(state, :errored, "worktree missing: #{path}", bump_errors: true)
  end

  defp apply_probe_result(state, {:error, :container_not_ready}) do
    transition(state, :errored, "workspace container is not ready yet", bump_errors: true)
  end

  defp apply_probe_result(state, {:error, :session_errored}) do
    transition(state, :errored, "mutagen reports problem", bump_errors: true)
  end

  defp apply_probe_result(state, {:error, :unknown}) do
    transition(state, :errored, "mutagen unreachable", bump_errors: true)
  end

  defp apply_probe_result(state, {:error, reason}) do
    transition(state, :errored, to_string_reason(reason), bump_errors: true)
  end

  # --- Transitions + broadcasts ---

  defp transition(state, new_status, error, opts \\ []) do
    # Gate through the state machine so illegal moves (e.g. a late
    # :running probe landing after the user stopped the session) don't
    # silently re-animate a dead sync. Invalid transitions are logged
    # and ignored — the stored state stays as-is.
    case BoomLooper.Source.Local.SyncMonitor.StateMachine.transition(
           state.status,
           new_status
         ) do
      {:ok, _} ->
        do_transition(state, new_status, error, opts)

      {:error, {:invalid_transition, from, to}} ->
        require Logger

        Logger.warning(
          "[SyncMonitor] ignored invalid transition #{inspect(from)} → #{inspect(to)} " <>
            "for workspace=#{state.workspace_id}" <>
            if(error, do: " (error: #{inspect(error)})", else: "")
        )

        state
    end
  end

  defp do_transition(state, new_status, error, opts) do
    new_errors =
      cond do
        Keyword.get(opts, :bump_errors, false) -> state.consecutive_errors + 1
        new_status == :running -> 0
        true -> state.consecutive_errors
      end

    new_state = %{
      state
      | status: new_status,
        last_error: error,
        last_checked_at: DateTime.utc_now(),
        consecutive_errors: new_errors
    }

    if state.status != new_status or state.last_error != error do
      broadcast(new_state)
    end

    new_state
  end

  defp broadcast(state) do
    BoomLooper.Events.SourceSync.publish(%BoomLooper.Events.SourceSync.Updated{
      workspace_id: state.workspace_id,
      status: status_map(state)
    })
  end

  defp status_map(state) do
    base = %{
      status: state.status,
      last_error: state.last_error,
      last_checked_at: state.last_checked_at
    }

    if state.sync_details do
      Map.put(base, :details, state.sync_details)
    else
      base
    end
  end

  # Exponential backoff: 5s × 2^n, capped at 60s. Reset when we reach
  # `:running` (consecutive_errors == 0).
  defp schedule_next_poll(state) do
    interval = poll_interval(state.consecutive_errors)
    Process.send_after(self(), :tick, interval)
  end

  defp poll_interval(0), do: @base_poll_interval

  defp poll_interval(n) when n > 0 do
    backoff = @base_poll_interval * :math.pow(2, min(n, 4)) |> trunc()
    min(backoff, @max_poll_interval)
  end

  defp default_container_name(workspace_id) do
    "bl-#{workspace_id}-workspace-1"
  end

  defp to_string_reason(reason) when is_binary(reason), do: reason
  defp to_string_reason(reason), do: inspect(reason)

  defp via(workspace_id) do
    {:via, Registry, {@registry, workspace_id}}
  end

  defp call(workspace_id, msg, default) do
    case whereis(workspace_id) do
      nil ->
        default

      pid ->
        try do
          GenServer.call(pid, msg, 1_000)
        catch
          :exit, _ -> default
        end
    end
  end

  defp cast(workspace_id, msg) do
    case whereis(workspace_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, msg)
    end
  end
end
