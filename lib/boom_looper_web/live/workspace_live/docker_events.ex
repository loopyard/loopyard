defmodule BoomLooperWeb.Live.WorkspaceLive.DockerEvents do
  @moduledoc """
  Docker Observer, WorkspaceServices, SourceSync, and WorkspaceSetup
  event handling extracted from WorkspaceLive.

  Every public `handle_*` function takes an event struct + socket and
  returns `{:noreply, socket}`. The WorkspaceLive `@impl` callbacks
  delegate here as one-liners.

  Shared helpers (`load_sidebar_from_observer`, `derive_workspace_state`,
  `guard_service_statuses`, `transition_workspace_state`) are public so
  mount and handle_event code in WorkspaceLive can call them too.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias BoomLooper.Events

  # ---------------------------------------------------------------------------
  # DockerObserver subscriber handlers
  # ---------------------------------------------------------------------------

  def handle_docker_changed(%Events.DockerObserver.Changed{}, socket) do
    ws_id = workspace_id(socket)
    {service_statuses, volumes} = load_sidebar_from_observer(nil, ws_id)
    guarded = guard_service_statuses(socket, service_statuses)
    new_state = derive_workspace_state(ws_id, guarded, socket.assigns.workspace_state)

    {:noreply,
     socket
     |> assign(:service_statuses, guarded)
     |> assign(:volumes, volumes)
     |> transition_workspace_state(new_state)}
  end

  def handle_docker_reset(%Events.DockerObserver.Reset{}, socket) do
    ws_id = workspace_id(socket)
    {service_statuses, volumes} = load_sidebar_from_observer(nil, ws_id)
    guarded = guard_service_statuses(socket, service_statuses)

    {:noreply,
     socket
     |> assign(:service_statuses, guarded)
     |> assign(:volumes, volumes)}
  end

  def handle_docker_disconnected(%Events.DockerObserver.Disconnected{}, socket) do
    {:noreply, assign(socket, :docker_connected?, false)}
  end

  def handle_docker_reconnected(%Events.DockerObserver.Reconnected{}, socket) do
    {:noreply, assign(socket, :docker_connected?, true)}
  end

  # ---------------------------------------------------------------------------
  # WorkspaceServices subscriber handlers
  # ---------------------------------------------------------------------------

  def handle_compose_result(%Events.WorkspaceServices.ComposeResult{workspace_id: workspace_id, result: result}, socket) do
    ws = socket.assigns.workspace
    ws_entry = socket.assigns[:workspace_entry]
    our_id = (ws_entry && ws_entry.id) || ws.id

    if workspace_id == our_id do
      target =
        case {socket.assigns.workspace_state, result} do
          {:starting, :ok} -> :started
          {:starting, {:error, _}} -> :stopped
          {:stopping, :ok} -> :stopped
          {:stopping, {:error, _}} -> :started
          _ -> socket.assigns.workspace_state
        end

      socket =
        case result do
          {:error, reason} ->
            put_flash(socket, :error, "Cluster didn't start: #{truncate(reason, 200)}")

          :ok ->
            socket
        end

      {:noreply, transition_workspace_state(socket, target)}
    else
      {:noreply, socket}
    end
  end

  def handle_services_updated(%Events.WorkspaceServices.ServicesUpdated{path: path}, socket) do
    ws = socket.assigns.workspace
    ws_entry = socket.assigns[:workspace_entry]

    matches = path == ws.path or
      (ws_entry && path == ws_entry[:path]) or
      (ws_entry && path == ws_entry[:compose_dir])

    if matches do
      ws_id = ws_entry && ws_entry.id || ws.id
      {service_statuses, _volumes} = load_sidebar_from_observer(path, ws_id)

      {:noreply, assign(socket, :service_statuses, guard_service_statuses(socket, service_statuses))}
    else
      {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # SourceSync subscriber handlers
  # ---------------------------------------------------------------------------

  def handle_source_sync(%Events.SourceSync.Updated{workspace_id: ws_id, status: status}, socket) do
    if ws_id == socket.assigns.workspace.id do
      {:noreply, assign(socket, :sync_status, status)}
    else
      {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # WorkspaceSetup subscriber handlers
  # ---------------------------------------------------------------------------

  def handle_setup_started(%Events.WorkspaceSetup.Started{workspace_id: id, attempt: attempt, started_at: at}, socket) do
    if id == socket.assigns.workspace.id do
      {:noreply, patch_setup(socket, %{phase: :running, attempts: attempt, started_at: at, error: nil})}
    else
      {:noreply, socket}
    end
  end

  def handle_setup_phase_started(%Events.WorkspaceSetup.PhaseStarted{workspace_id: id, phase: phase}, socket) do
    if id == socket.assigns.workspace.id do
      {:noreply, patch_setup(socket, %{phase: phase})}
    else
      {:noreply, socket}
    end
  end

  def handle_setup_phase_completed(%Events.WorkspaceSetup.PhaseCompleted{workspace_id: id}, socket) do
    if id == socket.assigns.workspace.id do
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_setup_phase_progress(%Events.WorkspaceSetup.PhaseProgress{workspace_id: id, payload: payload}, socket) do
    if id == socket.assigns.workspace.id do
      {:noreply, patch_setup(socket, %{progress: payload})}
    else
      {:noreply, socket}
    end
  end

  def handle_setup_completed(%Events.WorkspaceSetup.Completed{workspace_id: id, finished_at: at}, socket) do
    if id == socket.assigns.workspace.id do
      {:noreply, patch_setup(socket, %{phase: :ready, finished_at: at, error: nil})}
    else
      {:noreply, socket}
    end
  end

  def handle_setup_failed(%Events.WorkspaceSetup.Failed{workspace_id: id, error: error}, socket) do
    if id == socket.assigns.workspace.id do
      {:noreply, patch_setup(socket, %{phase: :failed, error: error, finished_at: DateTime.utc_now()})}
    else
      {:noreply, socket}
    end
  end

  def handle_setup_retry_scheduled(%Events.WorkspaceSetup.RetryScheduled{}, socket) do
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Public helpers — used by both event handlers and WorkspaceLive mount/events
  # ---------------------------------------------------------------------------

  @doc """
  Derive sidebar service + volume state from Docker.Observer's ETS cache.
  Zero docker calls — microsecond reads.
  """
  def load_sidebar_from_observer(_workspace_path, workspace_id) do
    service_statuses =
      BoomLooper.Docker.Observer.services_for(workspace_id)
      |> Enum.map(&annotate_exposure(&1, workspace_id))

    volumes =
      BoomLooper.Docker.Observer.volumes_for(workspace_id)
      |> Enum.map(fn v ->
        %{name: v.name, type: v.type, service: v.service, description: v.description}
      end)

    {service_statuses, volumes}
  end

  @doc """
  The single source of truth for the workspace Start/Stop pill.
  Returns one of :stopped | :starting | :started | :stopping | :partial.
  """
  def derive_workspace_state(_workspace_id, service_statuses, previous) do
    if not docker_connected?() do
      previous || :stopped
    else
      running_count = Enum.count(service_statuses, &(&1.status == :running))
      total_count = length(service_statuses)
      any_running? = running_count > 0
      all_running? = running_count == total_count and total_count > 0

      sm_previous = if previous == :partial, do: :started, else: previous

      target =
        case sm_previous do
          :starting -> if any_running?, do: :started, else: :starting
          :stopping -> if any_running?, do: :stopping, else: :stopped
          _ -> if any_running?, do: :started, else: :stopped
        end

      state =
        case BoomLooper.Cluster.StateMachine.transition(sm_previous || target, target) do
          {:ok, s} -> s
          {:error, _} -> if any_running?, do: :started, else: :stopped
        end

      if state == :started and not all_running? do
        :partial
      else
        state
      end
    end
  end

  @doc """
  Commit a new workspace_state and stamp the entered_at timestamp iff
  the state actually changed.
  """
  def transition_workspace_state(socket, new_state) do
    if socket.assigns.workspace_state == new_state do
      socket
    else
      socket
      |> assign(:workspace_state, new_state)
      |> assign(:workspace_state_since, DateTime.utc_now())
    end
  end

  @doc """
  Never replace a non-empty service list with []. Prevents sidebar flapping.
  """
  def guard_service_statuses(socket, new_statuses) do
    if new_statuses == [] and socket.assigns.service_statuses != [] do
      socket.assigns.service_statuses
    else
      new_statuses
    end
  end

  @doc """
  Explicit bypass for the guard when empty is legitimately the new truth
  (e.g. :workspace_stopped).
  """
  def force_assign_service_statuses(socket, new_statuses) do
    assign(socket, :service_statuses, new_statuses)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp workspace_id(socket) do
    socket.assigns.workspace_entry && socket.assigns.workspace_entry.id || socket.assigns.workspace.id
  end

  def docker_connected? do
    BoomLooper.Docker.Observer.connected?()
  rescue
    _ -> false
  end

  defp truncate(bin, max) when is_binary(bin) do
    if byte_size(bin) > max, do: binary_part(bin, 0, max) <> "…", else: bin
  end

  defp truncate(other, max), do: other |> inspect() |> truncate(max)

  defp annotate_exposure(svc, workspace_id) do
    case registry_entry_for_service(workspace_id, svc.name) do
      {:ok, entry} ->
        Map.merge(svc, %{
          exposed: entry.exposed,
          container_port: entry.container_port,
          host_port: entry.host_port
        })

      :none ->
        Map.merge(svc, %{exposed: false, container_port: nil, host_port: nil})
    end
  end

  defp registry_entry_for_service(workspace_id, service_name) do
    case BoomLooper.PortRegistry.list_for_workspace(workspace_id)
         |> Enum.find(&(&1.service == service_name)) do
      nil -> :none
      entry -> {:ok, entry}
    end
  end

  defp patch_setup(socket, changes) do
    case socket.assigns[:workspace_entry] do
      %{setup: setup} = entry ->
        new_setup = Map.merge(setup || %{}, changes)
        assign(socket, :workspace_entry, %{entry | setup: new_setup})

      %{} = entry ->
        assign(socket, :workspace_entry, Map.put(entry, :setup, changes))

      _ ->
        socket
    end
  end
end
