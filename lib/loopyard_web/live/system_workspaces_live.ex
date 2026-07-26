defmodule LoopyardWeb.SystemWorkspacesLive do
  @moduledoc """
  Cluster-wide workspace health: which workspaces are registered, are
  their supervisors alive, do they have running containers. This is for
  remote diagnosis and restart, NOT for browsing project content (use
  `/projects/:id` for that).

  Mounts instantly via `start_async/3` — `workspace_stats/0` is fast
  but the per-workspace container counts shell out, so they load in a
  second slice.
  """
  use LoopyardWeb, :live_view
  use LoopyardWeb.IExAware

  alias Loopyard.Events
  alias Loopyard.SystemStats

  @behaviour Loopyard.Events.DockerObserver.Subscriber
  @behaviour Loopyard.Events.ChatAgent.Subscriber
  @behaviour Loopyard.Events.WorkspaceServices.Subscriber

  @impl true
  def mount(_params, _session, socket) do
    # Container counts come from Docker.Observer's ETS cache — instant.
    # workspace_stats comes from Registry (also instant).
    container_counts = compute_container_counts()

    socket =
      socket
      |> assign_iex()
      |> assign(:workspaces, SystemStats.workspace_stats())
      |> assign(:container_counts, container_counts)

    if connected?(socket) do
      Loopyard.Docker.Observer.subscribe()
      Loopyard.ChatAgent.subscribe()
      Loopyard.Workspace.ServiceManager.subscribe()
      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  defp assign_iex(socket) do
    if connected?(socket),
      do: subscribe_iex(socket),
      else: assign(socket, :iex_session, %{level: nil})
  end

  # Bucket Observer's container list by workspace_id.
  defp compute_container_counts do
    Loopyard.Docker.Observer.containers()
    |> Enum.reduce(%{}, fn c, acc ->
      case c.workspace_id do
        nil ->
          acc

        ws_id ->
          Map.update(acc, ws_id, %{total: 1, running: bool_to_int(c.running)}, fn cur ->
            %{total: cur.total + 1, running: cur.running + bool_to_int(c.running)}
          end)
      end
    end)
  end

  defp bool_to_int(true), do: 1
  defp bool_to_int(_), do: 0

  # --- PubSub dispatch ---

  @impl true
  def handle_info(%Events.DockerObserver.Changed{} = e, socket), do: on_changed(e, socket)
  def handle_info(%Events.DockerObserver.Reset{} = e, socket), do: on_reset(e, socket)

  def handle_info(%Events.DockerObserver.Disconnected{} = e, socket),
    do: on_disconnected(e, socket)

  def handle_info(%Events.DockerObserver.Reconnected{} = e, socket), do: on_reconnected(e, socket)

  def handle_info(%Events.ChatAgent.Started{} = e, socket), do: on_started(e, socket)
  def handle_info(%Events.ChatAgent.Stopped{} = e, socket), do: on_stopped(e, socket)
  def handle_info(%Events.ChatAgent.Booting{} = e, socket), do: on_booting(e, socket)
  def handle_info(%Events.ChatAgent.Removed{} = e, socket), do: on_removed(e, socket)
  def handle_info(%Events.ChatAgent.StatusChanged{} = e, socket), do: on_status_changed(e, socket)
  def handle_info(%Events.ChatAgent.Resumed{} = e, socket), do: on_resumed(e, socket)
  def handle_info(%Events.ChatAgent.BootStatus{} = e, socket), do: on_boot_status(e, socket)
  def handle_info(%Events.ChatAgent.BootFailed{} = e, socket), do: on_boot_failed(e, socket)
  def handle_info(%Events.ChatAgent.Renamed{} = e, socket), do: on_renamed(e, socket)
  def handle_info(%Events.ChatAgent.Quarantined{} = e, socket), do: on_quarantined(e, socket)
  def handle_info(%Events.ChatAgent.Released{} = e, socket), do: on_released(e, socket)

  def handle_info(%Events.WorkspaceServices.ServicesUpdated{} = e, socket),
    do: on_services_updated(e, socket)

  def handle_info(%Events.WorkspaceServices.ComposeResult{} = e, socket),
    do: on_compose_result(e, socket)

  # Non-PubSub internal messages from the restart task.
  def handle_info({:workspace_restarted, ws_id, :ok}, socket) do
    {:noreply, socket |> put_flash(:info, "Restarted #{ws_id}") |> refresh()}
  end

  def handle_info({:workspace_restarted, ws_id, {:error, reason}}, socket) do
    {:noreply, put_flash(socket, :error, "Failed to restart #{ws_id}: #{inspect(reason)}")}
  end

  # Catch-all so unknown PubSub messages don't crash the LiveView.
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- DockerObserver subscriber callbacks ---

  @impl Events.DockerObserver.Subscriber
  def on_changed(_e, socket), do: {:noreply, refresh(socket)}
  @impl Events.DockerObserver.Subscriber
  def on_reset(_e, socket), do: {:noreply, assign(socket, :container_counts, %{})}
  @impl Events.DockerObserver.Subscriber
  def on_disconnected(_e, socket), do: {:noreply, socket}
  @impl Events.DockerObserver.Subscriber
  def on_reconnected(_e, socket), do: {:noreply, refresh(socket)}

  # --- ChatAgent subscriber callbacks ---
  # Any agent lifecycle event → re-pull workspace stats. Events that only
  # tweak per-agent metadata (rename, boot progress, quarantine flag)
  # don't change the /system/workspaces per-workspace counts so they no-op.

  @impl Events.ChatAgent.Subscriber
  def on_started(_e, socket), do: {:noreply, refresh(socket)}
  @impl Events.ChatAgent.Subscriber
  def on_stopped(_e, socket), do: {:noreply, refresh(socket)}
  @impl Events.ChatAgent.Subscriber
  def on_booting(_e, socket), do: {:noreply, refresh(socket)}
  @impl Events.ChatAgent.Subscriber
  def on_removed(_e, socket), do: {:noreply, refresh(socket)}
  @impl Events.ChatAgent.Subscriber
  def on_status_changed(_e, socket), do: {:noreply, refresh(socket)}
  @impl Events.ChatAgent.Subscriber
  def on_resumed(_e, socket), do: {:noreply, refresh(socket)}
  @impl Events.ChatAgent.Subscriber
  def on_boot_status(_e, socket), do: {:noreply, socket}
  @impl Events.ChatAgent.Subscriber
  def on_boot_failed(_e, socket), do: {:noreply, refresh(socket)}
  @impl Events.ChatAgent.Subscriber
  def on_renamed(_e, socket), do: {:noreply, socket}
  @impl Events.ChatAgent.Subscriber
  def on_quarantined(_e, socket), do: {:noreply, socket}
  @impl Events.ChatAgent.Subscriber
  def on_released(_e, socket), do: {:noreply, socket}

  # --- WorkspaceServices subscriber callbacks ---

  @impl Events.WorkspaceServices.Subscriber
  def on_services_updated(_e, socket), do: {:noreply, refresh(socket)}
  @impl Events.WorkspaceServices.Subscriber
  def on_compose_result(_e, socket), do: {:noreply, socket}

  defp refresh(socket) do
    socket
    |> assign(:workspaces, SystemStats.workspace_stats())
    |> assign(:container_counts, compute_container_counts())
  end

  @impl true
  def handle_event("restart_workspace", %{"id" => ws_id, "path" => path}, socket) do
    lv = self()

    Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
      Loopyard.WorkspaceSupervisor.stop_workspace(ws_id)

      case Loopyard.WorkspaceSupervisor.start_workspace(ws_id, path) do
        {:ok, _} -> send(lv, {:workspace_restarted, ws_id, :ok})
        {:error, reason} -> send(lv, {:workspace_restarted, ws_id, {:error, reason}})
      end
    end)

    {:noreply, put_flash(socket, :info, "Restarting #{ws_id}...")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_shell
      breadcrumbs={[{"Loopyard", "/"}, {"System", "/system"}, {"Workspaces", nil}]}
      iex_session={@iex_session}
      max_width={:lg}
      flash={@flash}
    >
      <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">
        Workspaces <span class="text-zinc-400 font-normal">({length(@workspaces)})</span>
      </h2>

      <div :if={@workspaces == []} class="text-sm text-zinc-500 dark:text-zinc-400">
        No workspaces registered
      </div>

      <div :if={@workspaces != []} class="space-y-2">
        <.workspace_row :for={ws <- @workspaces} ws={ws} containers={@container_counts} />
      </div>
    </.page_shell>
    """
  end

  attr :ws, :map, required: true
  attr :containers, :any, required: true

  defp workspace_row(assigns) do
    ~H"""
    <div class="rounded-sm border border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50 px-4 py-3">
      <div class="flex items-center justify-between gap-3">
        <div class="flex items-center gap-3 min-w-0">
          <div class={"w-2 h-2 rounded-full flex-none #{if @ws.group_alive && @ws.service_manager_alive, do: "bg-green-500", else: "bg-red-500"}"}>
          </div>
          <div class="min-w-0">
            <div class="flex items-center gap-2">
              <span class="text-sm font-medium">{@ws.project_name}</span>
              <span class="text-xs text-zinc-400 font-mono">{@ws.workspace_id}</span>
            </div>
            <div class="text-xs text-zinc-500 truncate font-mono">{@ws.path}</div>
          </div>
        </div>
        <div class="flex items-center gap-3 flex-none">
          <.health_pill label="Group" alive={@ws.group_alive} />
          <.health_pill label="ServiceMgr" alive={@ws.service_manager_alive} />
          <.container_pill containers={@containers} workspace_id={@ws.workspace_id} />
          <button
            :if={!@ws.group_alive || !@ws.service_manager_alive}
            phx-click="restart_workspace"
            phx-value-id={@ws.workspace_id}
            phx-value-path={@ws.path}
            class="text-xs font-medium text-amber-600 dark:text-amber-400 hover:bg-amber-50 dark:hover:bg-amber-500/10 rounded-sm px-2 py-1 transition-colors"
          >
            Restart
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :alive, :boolean, required: true

  defp health_pill(assigns) do
    ~H"""
    <span class={[
      "text-xs font-medium rounded-full px-2 py-0.5",
      if(@alive,
        do: "text-green-600 dark:text-green-400 bg-green-100 dark:bg-green-900/30",
        else: "text-red-600 dark:text-red-400 bg-red-100 dark:bg-red-900/30"
      )
    ]}>
      {@label}
    </span>
    """
  end

  attr :containers, :any, required: true
  attr :workspace_id, :string, required: true

  defp container_pill(assigns) do
    ~H"""
    <% c = Map.get(@containers, @workspace_id, %{total: 0, running: 0}) %>
    <span class="text-xs font-mono text-zinc-500" title={"#{c.running} running of #{c.total}"}>
      {c.running}/{c.total} containers
    </span>
    """
  end
end
