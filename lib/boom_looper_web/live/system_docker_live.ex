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

  @impl true
  def mount(_params, _session, socket) do
    # Containers + volumes come from Docker.Observer's ETS cache —
    # instant, zero docker calls. Stats are still async (slow).
    observer = BoomLooper.Docker.Observer.snapshot()

    socket =
      socket
      |> assign_iex()
      |> assign(:containers, observer.containers)
      |> assign(:volumes, observer.volumes)
      |> assign(:container_stats, AsyncResult.loading())

    if connected?(socket) do
      BoomLooper.Docker.Observer.subscribe()
      {:ok, start_async(socket, :container_stats, &SystemStats.docker_container_stats/0)}
    else
      {:ok, socket}
    end
  end

  defp assign_iex(socket) do
    if connected?(socket), do: subscribe_iex(socket), else: assign(socket, :iex_session, %{level: nil})
  end

  # Docker.Observer broadcasts when container/volume state changes.
  # We just swap the assigns — no docker calls from this LiveView.
  @impl true
  def handle_info({:docker_state_changed, snapshot}, socket) do
    {:noreply,
     socket
     |> assign(:containers, snapshot.containers)
     |> assign(:volumes, snapshot.volumes)}
  end

  # Observer lost connection to Docker — show whatever we had last
  def handle_info({:docker_state_reset}, socket) do
    {:noreply, socket}
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
    # The docker events stream will pick up the container destroy event
    # and trigger a re-snapshot automatically. Force an immediate one
    # so the user sees the container vanish in the same render cycle.
    BoomLooper.Docker.Observer.poll_now()
    {:noreply, socket}
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
        <span :if={is_list(@containers)} class="text-zinc-400 font-normal">({length(@containers)})</span>
      </h2>

      <%= cond do %>
        <% !is_list(@containers) -> %>
          <.skeleton rows={4} />
        <% @containers == [] -> %>
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
                <tr :for={c <- @containers} class="border-t border-zinc-200 dark:border-zinc-700/50">
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
        <span :if={is_list(@volumes)} class="text-zinc-400 font-normal">({length(@volumes)})</span>
      </h2>

      <%= cond do %>
        <% !is_list(@volumes) -> %>
          <.skeleton rows={4} />
        <% @volumes == [] -> %>
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
                <tr :for={v <- @volumes} class="border-t border-zinc-200 dark:border-zinc-700/50">
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
