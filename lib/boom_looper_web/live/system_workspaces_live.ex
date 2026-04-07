defmodule BoomLooperWeb.SystemWorkspacesLive do
  @moduledoc """
  Cluster-wide workspace health: which workspaces are registered, are
  their supervisors alive, do they have running containers. This is for
  remote diagnosis and restart, NOT for browsing project content (use
  `/projects/:id` for that).

  Mounts instantly via `start_async/3` — `workspace_stats/0` is fast
  but the per-workspace container counts shell out, so they load in a
  second slice.
  """
  use BoomLooperWeb, :live_view
  use BoomLooperWeb.IExAware

  alias Phoenix.LiveView.AsyncResult
  alias BoomLooper.SystemStats

  @refresh 5_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign_iex()
      |> assign(:workspaces, SystemStats.workspace_stats())
      |> assign(:container_counts, AsyncResult.loading())

    if connected?(socket) do
      # Multiplayer: anyone watching this page sees agent + service
      # changes the moment they happen, instead of waiting for the
      # next 5s poll. The poll is still here as a fallback in case a
      # broadcast gets dropped.
      BoomLooper.ChatAgent.subscribe()
      BoomLooper.Workspace.ServiceManager.subscribe()
      Process.send_after(self(), :refresh, @refresh)
      {:ok, kick_slices(socket)}
    else
      {:ok, socket}
    end
  end

  defp assign_iex(socket) do
    if connected?(socket), do: subscribe_iex(socket), else: assign(socket, :iex_session, %{level: nil})
  end

  defp kick_slices(socket) do
    start_async(socket, :container_counts, &load_container_counts/0)
  end

  # One docker ps call, bucketed by `bl-<workspace_id>-` prefix. We do NOT
  # do per-workspace docker calls — that would be N shell-outs.
  defp load_container_counts do
    BoomLooper.Docker.list_containers(prefix: "bl-")
    |> Enum.reduce(%{}, fn c, acc ->
      case Regex.run(~r/^bl-([a-f0-9]+)-/, c.name) do
        [_, ws_id] ->
          Map.update(acc, ws_id, %{total: 1, running: bool_to_int(c.running)}, fn cur ->
            %{total: cur.total + 1, running: cur.running + bool_to_int(c.running)}
          end)

        _ ->
          acc
      end
    end)
  end

  defp bool_to_int(true), do: 1
  defp bool_to_int(_), do: 0

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh)
    {:noreply, refresh(socket)}
  end

  # Any agent lifecycle event → re-pull workspace stats and kick the
  # async container count fetch.
  def handle_info({event, _}, socket)
      when event in [:chat_agent_started, :chat_agent_stopped, :chat_agent_booting,
                     :chat_agent_removed, :chat_agent_status_changed, :chat_agent_resumed] do
    {:noreply, refresh(socket)}
  end

  def handle_info({:services_updated, _path, _statuses}, socket) do
    {:noreply, refresh(socket)}
  end

  # Catch-all so unknown PubSub messages don't crash the LiveView.
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(socket) do
    socket
    |> assign(:workspaces, SystemStats.workspace_stats())
    |> kick_slices()
  end

  @impl true
  def handle_async(key, {:ok, value}, socket) do
    {:noreply, assign(socket, key, AsyncResult.ok(socket.assigns[key] || AsyncResult.loading(), value))}
  end

  def handle_async(key, {:exit, reason}, socket) do
    {:noreply, assign(socket, key, AsyncResult.failed(socket.assigns[key] || AsyncResult.loading(), reason))}
  end

  @impl true
  def handle_event("restart_workspace", %{"id" => ws_id, "path" => path}, socket) do
    BoomLooper.WorkspaceSupervisor.stop_workspace(ws_id)
    Process.sleep(500)

    case BoomLooper.WorkspaceSupervisor.start_workspace(ws_id, path) do
      {:ok, _} -> {:noreply, put_flash(socket, :info, "Restarted #{ws_id}")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100">
      <.header breadcrumbs={[{"Boom Looper", "/"}, {"System", "/system"}, {"Workspaces", nil}]} iex_session={@iex_session} />

      <div class="max-w-5xl mx-auto px-4 md:px-6 py-6">
        <.flash_banner flash={@flash} kind={:info} />
        <.flash_banner flash={@flash} kind={:error} />

        <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">
          Workspaces <span class="text-zinc-400 font-normal">({length(@workspaces)})</span>
        </h2>

        <div :if={@workspaces == []} class="text-sm text-zinc-400 dark:text-zinc-500">No workspaces registered</div>

        <div :if={@workspaces != []} class="space-y-2">
          <.workspace_row :for={ws <- @workspaces} ws={ws} containers={@container_counts} />
        </div>
      </div>
    </div>
    """
  end

  attr :ws, :map, required: true
  attr :containers, :any, required: true

  defp workspace_row(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50 px-4 py-3">
      <div class="flex items-center justify-between gap-3">
        <div class="flex items-center gap-3 min-w-0">
          <div class={"w-2 h-2 rounded-full flex-none #{if @ws.group_alive && @ws.service_manager_alive, do: "bg-green-500", else: "bg-red-500"}"}></div>
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
            class="text-xs font-medium text-amber-600 dark:text-amber-400 hover:bg-amber-50 dark:hover:bg-amber-500/10 rounded px-2 py-1 transition-colors"
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
      if(@alive, do: "text-green-600 dark:text-green-400 bg-green-100 dark:bg-green-900/30",
                  else: "text-red-600 dark:text-red-400 bg-red-100 dark:bg-red-900/30")
    ]}>
      {@label}
    </span>
    """
  end

  attr :containers, :any, required: true
  attr :workspace_id, :string, required: true

  defp container_pill(assigns) do
    ~H"""
    <%= case @containers do %>
      <% %{ok?: true, result: counts} -> %>
        <% c = Map.get(counts, @workspace_id, %{total: 0, running: 0}) %>
        <span class="text-xs font-mono text-zinc-500" title={"#{c.running} running of #{c.total}"}>
          {c.running}/{c.total} containers
        </span>
      <% _ -> %>
        <span class="text-xs font-mono text-zinc-300 dark:text-zinc-600">…</span>
    <% end %>
    """
  end
end
