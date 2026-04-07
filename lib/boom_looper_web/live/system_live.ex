defmodule BoomLooperWeb.SystemLive do
  @moduledoc """
  Cluster overview page. Shows host stats, BEAM totals, and counts.
  Drill into `/system/workspaces` and `/system/docker` for details.

  Every slow slice loads via `start_async/3` so mount paints instantly.
  Slices refresh on independent timers — fast slices (BEAM, counts)
  refresh every 2s, slow slices (host shell-outs) every 5s. A hung
  Docker call never blocks the page or other slices.
  """
  use BoomLooperWeb, :live_view
  use BoomLooperWeb.IExAware

  alias Phoenix.LiveView.AsyncResult
  alias BoomLooper.SystemStats

  # Each slice has its own refresh cadence. Fast in-VM lookups can refresh
  # often; shell-outs to vm_stat / df / docker are kept slower so we don't
  # pile up zombie processes if the host is unhappy.
  @fast_refresh 2_000
  @slow_refresh 5_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign_iex()
      |> assign(:host_cpu, AsyncResult.loading())
      |> assign(:host_memory, AsyncResult.loading())
      |> assign(:host_disk, AsyncResult.loading())
      |> assign(:host_uptime, AsyncResult.loading())
      |> assign(:beam, SystemStats.beam_stats())
      |> assign(:counts, AsyncResult.loading())
      |> assign(:logs, BoomLooper.LogBuffer.recent(20))

    if connected?(socket) do
      schedule_refresh(:fast)
      schedule_refresh(:slow)
      {:ok, kick_all_slices(socket)}
    else
      {:ok, socket}
    end
  end

  defp assign_iex(socket) do
    if connected?(socket), do: subscribe_iex(socket), else: assign(socket, :iex_session, %{level: nil})
  end

  defp schedule_refresh(:fast), do: Process.send_after(self(), :refresh_fast, @fast_refresh)
  defp schedule_refresh(:slow), do: Process.send_after(self(), :refresh_slow, @slow_refresh)

  # Spawn one Task per slice. They run in parallel and each populates
  # exactly one assign on completion via handle_async/3.
  defp kick_all_slices(socket) do
    socket
    |> kick_fast_slices()
    |> kick_slow_slices()
  end

  defp kick_fast_slices(socket) do
    socket
    |> start_async(:counts, &load_counts/0)
  end

  defp kick_slow_slices(socket) do
    socket
    |> start_async(:host_cpu, &SystemStats.host_cpu/0)
    |> start_async(:host_memory, &SystemStats.host_memory/0)
    |> start_async(:host_disk, &SystemStats.host_disk/0)
    |> start_async(:host_uptime, &SystemStats.host_uptime/0)
  end

  defp load_counts do
    %{
      workspaces: length(BoomLooper.ProjectRegistry.list_projects()),
      agents: length(BoomLooper.ChatAgent.list_agents()),
      cli: length(SystemStats.claude_cli_processes())
    }
  end

  # --- Refresh timers ---

  @impl true
  def handle_info(:refresh_fast, socket) do
    schedule_refresh(:fast)
    # BEAM stats are pure VM lookups; refresh in-place. Tail logs too.
    {:noreply,
     socket
     |> assign(:beam, SystemStats.beam_stats())
     |> assign(:logs, BoomLooper.LogBuffer.recent(20))
     |> kick_fast_slices()}
  end

  def handle_info(:refresh_slow, socket) do
    schedule_refresh(:slow)
    {:noreply, kick_slow_slices(socket)}
  end

  # --- Async results ---

  @impl true
  def handle_async(key, {:ok, value}, socket) do
    {:noreply, assign(socket, key, AsyncResult.ok(socket.assigns[key] || AsyncResult.loading(), value))}
  end

  def handle_async(key, {:exit, reason}, socket) do
    {:noreply, assign(socket, key, AsyncResult.failed(socket.assigns[key] || AsyncResult.loading(), reason))}
  end

  # --- Events ---

  @impl true
  def handle_event("reboot", _params, socket) do
    for agent <- BoomLooper.ChatAgent.list_agents() do
      BoomLooper.ChatAgent.stop_agent(agent.id)
      BoomLooper.ChatAgent.remove_agent(agent.id)
    end

    Task.start(fn ->
      Application.stop(:boom_looper)
      Process.sleep(500)
      Application.ensure_all_started(:boom_looper)
    end)

    {:noreply, put_flash(socket, :info, "Rebooting...")}
  end

  # =============================================
  # Render
  # =============================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100">
      <.header breadcrumbs={[{"Boom Looper", "/"}, {"System", nil}]} iex_session={@iex_session}>
        <button phx-click="reboot" data-confirm="This will stop all agents and restart the app. Continue?"
          class="text-xs font-medium text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-500/10 rounded px-2 py-1 transition-colors">
          Reboot
        </button>
      </.header>

      <div class="max-w-5xl mx-auto px-4 md:px-6 py-6 space-y-8">
        <.host_section host_cpu={@host_cpu} host_memory={@host_memory} host_disk={@host_disk} host_uptime={@host_uptime} />
        <.beam_section beam={@beam} />
        <.drilldown_section counts={@counts} />
        <.log_section logs={@logs} />
      </div>
    </div>
    """
  end

  # --- Host System ---

  defp host_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">Host System</h2>
      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <.host_card :let={cpu} label="CPU" async={@host_cpu}>
          <div class="text-2xl font-semibold font-mono">{cpu.cores} <span class="text-sm text-zinc-400">cores</span></div>
          <div class="mt-2 text-xs font-mono text-zinc-500">
            Load avg:
            <span :for={{load, i} <- Enum.with_index(cpu.load_avg)} class={load_color(load, cpu.cores)}>
              {Float.round(load, 2)}<span :if={i < 2} class="text-zinc-400">,</span>
            </span>
          </div>
        </.host_card>

        <.host_card :let={mem} label="Memory" async={@host_memory}>
          <% pct = mem_bar_pct(mem) %>
          <div class="text-2xl font-semibold font-mono">{format_bytes(mem.used)} <span class="text-sm text-zinc-400">/ {format_bytes(mem.total)}</span></div>
          <div class="mt-2 h-2 bg-zinc-200 dark:bg-zinc-700 rounded-full overflow-hidden">
            <div class={"h-full rounded-full #{if pct > 80, do: "bg-red-500", else: "bg-violet-500"}"} style={"width: #{pct}%"}></div>
          </div>
          <div class="mt-1 text-xs font-mono text-zinc-400">{pct}% used</div>
        </.host_card>

        <.host_card :let={disk} label="Disk (/)" async={@host_disk}>
          <div class="text-2xl font-semibold font-mono">{disk.used} <span class="text-sm text-zinc-400">/ {disk.total}</span></div>
          <div class="mt-2 h-2 bg-zinc-200 dark:bg-zinc-700 rounded-full overflow-hidden">
            <div class={"h-full rounded-full #{if String.contains?(disk.use_pct || "", "9"), do: "bg-red-500", else: "bg-violet-500"}"} style={"width: #{disk.use_pct}"}></div>
          </div>
          <div class="mt-1 text-xs font-mono text-zinc-400">{disk.use_pct} used &middot; {disk.available} free</div>
        </.host_card>
      </div>
      <div class="mt-2 text-xs text-zinc-400 dark:text-zinc-500 font-mono min-h-[1em]">
        <%= case @host_uptime do %>
          <% %{ok?: true, result: uptime} -> %>{uptime}
          <% _ -> %><span class="text-zinc-300 dark:text-zinc-600">loading uptime…</span>
        <% end %>
      </div>
    </section>
    """
  end

  # Generic card with async loading skeleton + error fallback. The slot
  # receives `:let={result}` so each card can render its own data shape
  # without re-implementing the loading/error states.
  attr :label, :string, required: true
  attr :async, :any, required: true
  slot :inner_block, required: true

  defp host_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50 p-4 min-h-[6rem]">
      <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 mb-2">{@label}</div>
      <%= case @async do %>
        <% %{ok?: true, result: result} -> %>
          {render_slot(@inner_block, result)}
        <% %{failed: failed} when failed != nil -> %>
          <div class="text-xs text-red-500">failed to load</div>
        <% _ -> %>
          <.skeleton variant={:card} />
      <% end %>
    </div>
    """
  end

  # --- BEAM ---

  defp beam_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">BEAM VM</h2>
      <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
        <.stat_card label="Memory" value={format_bytes(@beam.total)} />
        <.stat_card label="Processes" value={format_number(@beam.process_count)} />
        <.stat_card label="ETS" value={format_bytes(@beam.ets)} />
        <.stat_card label="Schedulers" value={@beam.schedulers} />
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50 px-3 py-2">
      <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500">{@label}</div>
      <div class="text-sm font-semibold font-mono mt-0.5">{@value}</div>
    </div>
    """
  end

  # --- Drill-down to deeper pages ---

  defp drilldown_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">Cluster</h2>
      <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
        <.drilldown_card href="/system/workspaces" title="Workspaces" subtitle="Per-workspace health & restart controls">
          <%= case @counts do %>
            <% %{ok?: true, result: %{workspaces: w, agents: a}} -> %>
              <span class="font-mono">{w}</span> workspaces · <span class="font-mono">{a}</span> agents
            <% _ -> %>
              <span class="text-zinc-400">loading…</span>
          <% end %>
        </.drilldown_card>

        <.drilldown_card href="/system/docker" title="Docker Cluster" subtitle="All containers, volumes, resource stats">
          <%= case @counts do %>
            <% %{ok?: true, result: %{cli: cli}} -> %>
              <span class="font-mono">{cli}</span> claude CLI processes
            <% _ -> %>
              <span class="text-zinc-400">loading…</span>
          <% end %>
        </.drilldown_card>
      </div>
    </section>
    """
  end

  attr :href, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  slot :inner_block, required: true

  defp drilldown_card(assigns) do
    ~H"""
    <.link navigate={@href}
      class="block rounded-lg border border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50 p-4 hover:border-violet-400 dark:hover:border-violet-500 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors">
      <div class="flex items-center justify-between">
        <div>
          <div class="text-sm font-semibold">{@title}</div>
          <div class="text-xs text-zinc-500 dark:text-zinc-400 mt-0.5">{@subtitle}</div>
          <div class="text-xs text-zinc-600 dark:text-zinc-400 font-mono mt-2">{render_slot(@inner_block)}</div>
        </div>
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4 text-zinc-400">
          <path fill-rule="evenodd" d="M7.21 14.77a.75.75 0 0 1 .02-1.06L11.168 10 7.23 6.29a.75.75 0 1 1 1.04-1.08l4.5 4.25a.75.75 0 0 1 0 1.08l-4.5 4.25a.75.75 0 0 1-1.06-.02Z" clip-rule="evenodd" />
        </svg>
      </div>
    </.link>
    """
  end

  # --- Recent Logs ---

  defp log_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">
        Recent Logs <span class="text-zinc-400 font-normal">(last 20)</span>
      </h2>
      <div class="rounded-lg border border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50 overflow-hidden">
        <div class="px-4 py-3 text-xs font-mono text-zinc-600 dark:text-zinc-400 space-y-0.5 max-h-64 overflow-y-auto">
          <div :if={@logs == []} class="text-zinc-400">no recent logs</div>
          <div :for={entry <- @logs}>
            <span class={log_level_class(entry.level)}>[{entry.level}]</span>
            <span>{entry.message}</span>
          </div>
        </div>
      </div>
    </section>
    """
  end

end
