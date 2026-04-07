defmodule BoomLooperWeb.SystemDockerLive do
  @moduledoc """
  Cluster-wide Docker view: every `bl-*` container, every `bl-*` volume,
  resource stats, and global controls (kill containers, prune). This is
  for cluster oversight and remote fixing — explicitly NOT a duplicate
  of `/projects/:id` (project-scoped) or `/system/workspaces/:id`
  (workspace-scoped). If a behavior already exists for project pages,
  link there instead of reimplementing it.

  All slices load via `start_async/3`. Mount paints instantly with
  loading skeletons; each slice fills in independently.
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
      |> assign(:containers, AsyncResult.loading())
      |> assign(:container_stats, AsyncResult.loading())
      |> assign(:volumes, AsyncResult.loading())

    if connected?(socket) do
      # Multiplayer: container/agent lifecycle changes from any source
      # (other tabs, agents, manual `docker rm`) trigger a refresh.
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
    socket
    |> start_async(:containers, fn -> BoomLooper.Docker.list_containers(prefix: "bl-") end)
    |> start_async(:container_stats, &SystemStats.docker_container_stats/0)
    |> start_async(:volumes, &BoomLooper.VolumeManager.list_all_volumes/0)
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh)
    {:noreply, kick_slices(socket)}
  end

  def handle_info({event, _}, socket)
      when event in [:chat_agent_started, :chat_agent_stopped, :chat_agent_booting,
                     :chat_agent_removed, :chat_agent_status_changed, :chat_agent_resumed] do
    {:noreply, kick_slices(socket)}
  end

  def handle_info({:services_updated, _path, _statuses}, socket) do
    {:noreply, kick_slices(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_async(key, {:ok, value}, socket) do
    {:noreply, assign(socket, key, AsyncResult.ok(socket.assigns[key] || AsyncResult.loading(), value))}
  end

  def handle_async(key, {:exit, reason}, socket) do
    {:noreply, assign(socket, key, AsyncResult.failed(socket.assigns[key] || AsyncResult.loading(), reason))}
  end

  @impl true
  def handle_event("kill_container", %{"name" => name}, socket) do
    BoomLooper.Docker.docker(["rm", "-f", name])
    {:noreply, kick_slices(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100">
      <.header breadcrumbs={[{"Boom Looper", "/"}, {"System", "/system"}, {"Docker", nil}]} iex_session={@iex_session} />

      <div class="max-w-6xl mx-auto px-4 md:px-6 py-6 space-y-8">
        <.containers_section containers={@containers} stats={@container_stats} />
        <.volumes_section volumes={@volumes} />
      </div>
    </div>
    """
  end

  defp containers_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">
        Containers
        <span :if={@containers.ok?} class="text-zinc-400 font-normal">({length(@containers.result)})</span>
      </h2>

      <%= cond do %>
        <% !@containers.ok? -> %>
          <.skeleton rows={4} />
        <% @containers.result == [] -> %>
          <div class="text-sm text-zinc-400 dark:text-zinc-500">No bl-* containers running</div>
        <% true -> %>
          <div class="rounded-lg border border-zinc-200 dark:border-zinc-700/80 overflow-hidden">
            <table class="w-full text-xs">
              <thead>
                <tr class="bg-zinc-100 dark:bg-zinc-800 text-zinc-500 dark:text-zinc-400 text-left">
                  <th class="px-3 py-2 font-medium w-8"></th>
                  <th class="px-3 py-2 font-medium">Container</th>
                  <th class="px-3 py-2 font-medium">CPU</th>
                  <th class="px-3 py-2 font-medium">Memory</th>
                  <th class="px-3 py-2 font-medium">PIDs</th>
                  <th class="px-3 py-2 font-medium">Status</th>
                  <th class="px-3 py-2 font-medium w-16"></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={c <- @containers.result} class="border-t border-zinc-200 dark:border-zinc-700/50">
                  <td class="px-3 py-2">
                    <div class={"w-2 h-2 rounded-full #{if c.running, do: "bg-green-500", else: "bg-zinc-400"}"}></div>
                  </td>
                  <td class="px-3 py-2 font-mono">{c.name}</td>
                  <% stat = container_stat(@stats, c.name) %>
                  <td class="px-3 py-2 font-mono">{stat_field(stat, :cpu)}</td>
                  <td class="px-3 py-2 font-mono">{stat_field(stat, :mem_usage)}</td>
                  <td class="px-3 py-2 font-mono">{stat_field(stat, :pids)}</td>
                  <td class="px-3 py-2 font-mono text-zinc-500 truncate max-w-[200px]" title={c.status}>{c.status}</td>
                  <td class="px-3 py-2">
                    <button phx-click="kill_container" phx-value-name={c.name}
                      data-confirm={"Force-remove container #{c.name}?"}
                      class="text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-500/10 rounded px-1.5 py-0.5 font-medium transition-colors">
                      rm -f
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
      <% end %>
    </section>
    """
  end

  defp volumes_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">
        Volumes
        <span :if={@volumes.ok?} class="text-zinc-400 font-normal">({length(@volumes.result)})</span>
      </h2>

      <%= cond do %>
        <% !@volumes.ok? -> %>
          <.skeleton rows={4} />
        <% @volumes.result == [] -> %>
          <div class="text-sm text-zinc-400 dark:text-zinc-500">No bl-* volumes</div>
        <% true -> %>
          <div class="rounded-lg border border-zinc-200 dark:border-zinc-700/80 overflow-hidden">
            <table class="w-full text-xs">
              <thead>
                <tr class="bg-zinc-100 dark:bg-zinc-800 text-zinc-500 dark:text-zinc-400 text-left">
                  <th class="px-3 py-2 font-medium">Volume</th>
                  <th class="px-3 py-2 font-medium">Type</th>
                  <th class="px-3 py-2 font-medium">Service</th>
                  <th class="px-3 py-2 font-medium">Description</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={v <- @volumes.result} class="border-t border-zinc-200 dark:border-zinc-700/50">
                  <td class="px-3 py-2 font-mono">{v.name}</td>
                  <td class="px-3 py-2 font-mono text-zinc-500">{v.type}</td>
                  <td class="px-3 py-2 font-mono text-zinc-500">{v.service}</td>
                  <td class="px-3 py-2 text-zinc-500">{v.description}</td>
                </tr>
              </tbody>
            </table>
          </div>
      <% end %>
    </section>
    """
  end

  defp container_stat(%{ok?: true, result: stats}, name), do: Map.get(stats, name)
  defp container_stat(_, _), do: nil

  defp stat_field(nil, _), do: "-"
  defp stat_field(stat, key), do: Map.get(stat, key, "-")
end
