defmodule BoomLooperWeb.SystemLive do
  use BoomLooperWeb, :live_view

  @refresh_interval 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    {:ok, refresh_stats(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, refresh_stats(socket)}
  end

  @impl true
  def handle_event("kill_container", %{"id" => agent_id}, socket) do
    BoomLooper.ChatAgent.stop_agent(agent_id)
    BoomLooper.ChatAgent.remove_agent(agent_id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("kill_process", %{"pid" => pid_str}, socket) do
    System.cmd("kill", ["-9", pid_str], stderr_to_stdout: true)
    {:noreply, socket}
  end

  @impl true
  def handle_event("restart_session", %{"id" => agent_id}, socket) do
    BoomLooper.ChatAgent.restart_session(agent_id)
    {:noreply, socket}
  end

  def handle_event("restart_workspace", %{"id" => ws_id, "path" => path}, socket) do
    # Stop the dead workspace group if it exists
    BoomLooper.WorkspaceSupervisor.stop_workspace(ws_id)
    Process.sleep(500)

    # Restart it
    case BoomLooper.WorkspaceSupervisor.start_workspace(ws_id, path) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Workspace #{ws_id} restarted")}
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to restart #{ws_id}: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("reboot", _params, socket) do
    # Stop all agents
    for agent <- BoomLooper.ChatAgent.list_agents() do
      BoomLooper.ChatAgent.stop_agent(agent.id)
      BoomLooper.ChatAgent.remove_agent(agent.id)
    end

    # Restart the application (reloads code + restarts supervisor tree)
    Task.start(fn ->
      Application.stop(:boom_looper)
      Process.sleep(500)
      Application.ensure_all_started(:boom_looper)
    end)

    {:noreply, put_flash(socket, :info, "Rebooting...")}
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_interval)

  defp refresh_stats(socket) do
    socket
    |> assign(:host, BoomLooper.SystemStats.host_stats())
    |> assign(:beam, BoomLooper.SystemStats.beam_stats())
    |> assign(:agents, BoomLooper.SystemStats.agent_stats())
    |> assign(:workspaces, BoomLooper.SystemStats.workspace_stats())
    |> assign(:cli_processes, BoomLooper.SystemStats.all_cli_processes())
    |> assign(:service_containers, BoomLooper.SystemStats.service_stats())
    |> assign(:logs, BoomLooper.LogBuffer.recent(50))
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when is_integer(bytes) and bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes) when is_integer(bytes) and bytes < 1_073_741_824, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp format_bytes(bytes) when is_integer(bytes), do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"
  defp format_bytes(bytes) when is_float(bytes), do: format_bytes(round(bytes))
  defp format_bytes(_), do: "?"

  defp format_rss(kb) when kb < 1024, do: "#{kb} KB"
  defp format_rss(kb), do: "#{Float.round(kb / 1024, 1)} MB"

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_number(n), do: to_string(n)

  defp mem_bar_pct(%{total: total, used: used}) when total > 0 do
    Float.round(used / total * 100, 1)
  end

  defp mem_bar_pct(_), do: 0

  defp load_color(load, cores) when load < cores * 0.5, do: "text-green-500"
  defp load_color(load, cores) when load < cores * 0.8, do: "text-amber-500"
  defp load_color(_, _), do: "text-red-500"

  # =============================================
  # Render
  # =============================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100">
      <header class="h-14 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center justify-between px-4 md:px-6">
        <div class="flex items-center gap-3">
          <.link navigate="/" class="text-sm text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors">&larr; Back</.link>
          <h1 class="text-lg font-semibold tracking-tight">System</h1>
        </div>
        <div class="flex items-center gap-4">
          <span class="text-xs text-zinc-400 dark:text-zinc-500 font-mono">auto-refreshing every 3s</span>
          <button phx-click="reboot" data-confirm="This will stop all agents, tear down containers, and restart the app. Continue?"
            class="text-xs font-medium text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-500/10 rounded px-2 py-1 transition-colors">
            Reboot
          </button>
        </div>
      </header>

      <div class="max-w-6xl mx-auto px-4 md:px-6 py-6 space-y-8">
        <.host_section host={@host} />
        <.app_section beam={@beam} agent_count={length(@agents)} cli_count={length(@cli_processes)} />
        <.workspaces_section workspaces={@workspaces} />
        <.agents_section agents={@agents} />
        <.service_containers_section containers={@service_containers} />
        <.cli_section processes={@cli_processes} />
        <.log_section logs={@logs} />
      </div>
    </div>
    """
  end

  # --- Host System ---

  defp host_section(assigns) do
    mem_pct = mem_bar_pct(assigns.host.memory)
    assigns = assign(assigns, :mem_pct, mem_pct)

    ~H"""
    <section>
      <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">Host System</h2>
      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <%!-- CPU --%>
        <div class="rounded-lg border border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50 p-4">
          <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 mb-2">CPU</div>
          <div class="text-2xl font-semibold font-mono">{@host.cpu.cores} <span class="text-sm text-zinc-400">cores</span></div>
          <div class="mt-2 text-xs font-mono text-zinc-500">
            Load avg:
            <span :for={{load, i} <- Enum.with_index(@host.cpu.load_avg)} class={load_color(load, @host.cpu.cores)}>
              {Float.round(load, 2)}<span :if={i < 2} class="text-zinc-400">,</span>
            </span>
          </div>
        </div>

        <%!-- Memory --%>
        <div class="rounded-lg border border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50 p-4">
          <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 mb-2">Memory</div>
          <div class="text-2xl font-semibold font-mono">{format_bytes(@host.memory.used)} <span class="text-sm text-zinc-400">/ {format_bytes(@host.memory.total)}</span></div>
          <div class="mt-2 h-2 bg-zinc-200 dark:bg-zinc-700 rounded-full overflow-hidden">
            <div class={"h-full rounded-full #{if @mem_pct > 80, do: "bg-red-500", else: "bg-violet-500"}"} style={"width: #{@mem_pct}%"}></div>
          </div>
          <div class="mt-1 text-xs font-mono text-zinc-400">{@mem_pct}% used</div>
        </div>

        <%!-- Disk --%>
        <div class="rounded-lg border border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50 p-4">
          <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 mb-2">Disk (/)</div>
          <div class="text-2xl font-semibold font-mono">{@host.disk.used} <span class="text-sm text-zinc-400">/ {@host.disk.total}</span></div>
          <div class="mt-2 h-2 bg-zinc-200 dark:bg-zinc-700 rounded-full overflow-hidden">
            <div class={"h-full rounded-full #{if String.contains?(@host.disk.use_pct || "", "9"), do: "bg-red-500", else: "bg-violet-500"}"} style={"width: #{@host.disk.use_pct}"}></div>
          </div>
          <div class="mt-1 text-xs font-mono text-zinc-400">{@host.disk.use_pct} used &middot; {@host.disk.available} free</div>
        </div>
      </div>
      <div class="mt-2 text-xs text-zinc-400 dark:text-zinc-500 font-mono">{@host.uptime}</div>
    </section>
    """
  end

  # --- App Totals ---

  defp app_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">BoomLooper App</h2>
      <div class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-6 gap-3">
        <.stat_card label="Agents" value={@agent_count} />
        <.stat_card label="Claude Processes" value={@cli_count} />
        <.stat_card label="BEAM Memory" value={format_bytes(@beam.total)} />
        <.stat_card label="BEAM Processes" value={format_number(@beam.process_count)} />
        <.stat_card label="ETS Memory" value={format_bytes(@beam.ets)} />
        <.stat_card label="Schedulers" value={@beam.schedulers} />
      </div>
    </section>
    """
  end

  defp stat_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50 px-3 py-2">
      <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500">{@label}</div>
      <div class="text-sm font-semibold font-mono mt-0.5">{@value}</div>
    </div>
    """
  end

  # --- Workspaces ---

  defp workspaces_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">
        Workspaces <span class="text-zinc-400 font-normal">({length(@workspaces)})</span>
      </h2>
      <div :if={@workspaces == []} class="text-sm text-zinc-400 dark:text-zinc-500">No workspaces registered</div>
      <div :if={@workspaces != []} class="space-y-2">
        <div :for={ws <- @workspaces} class="rounded-lg border border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50 px-4 py-3">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-3 min-w-0">
              <div class={"w-2 h-2 rounded-full flex-none #{if ws.group_alive && ws.service_manager_alive, do: "bg-green-500", else: "bg-red-500"}"}></div>
              <div class="min-w-0">
                <span class="text-sm font-medium">{ws.project_name}</span>
                <span class="text-xs text-zinc-400 ml-2 font-mono">{ws.workspace_id}</span>
                <div class="text-xs text-zinc-500 truncate">{ws.path}</div>
              </div>
            </div>
            <div class="flex items-center gap-2 flex-none">
              <div class="text-xs text-right space-y-0.5 mr-3">
                <div>
                  <span class="text-zinc-400">Group:</span>
                  <span class={if ws.group_alive, do: "text-green-600 dark:text-green-400", else: "text-red-600 dark:text-red-400 font-semibold"}>
                    {if ws.group_alive, do: "alive", else: "dead"}
                  </span>
                </div>
                <div>
                  <span class="text-zinc-400">ServiceMgr:</span>
                  <span class={if ws.service_manager_alive, do: "text-green-600 dark:text-green-400", else: "text-red-600 dark:text-red-400 font-semibold"}>
                    {if ws.service_manager_alive, do: "alive", else: "dead"}
                  </span>
                </div>
              </div>
              <button
                :if={!ws.group_alive || !ws.service_manager_alive}
                phx-click="restart_workspace"
                phx-value-id={ws.workspace_id}
                phx-value-path={ws.path}
                class="text-xs font-medium text-amber-600 dark:text-amber-400 hover:bg-amber-50 dark:hover:bg-amber-500/10 rounded px-2 py-1 transition-colors"
              >
                Restart
              </button>
              <span
                :if={ws.group_alive && ws.service_manager_alive}
                class="text-xs text-green-600 dark:text-green-400 px-2 py-1"
              >
                OK
              </span>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # --- Per-Agent Breakdown ---

  defp agents_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">
        Per-Agent Resources <span class="text-zinc-400 font-normal">({length(@agents)})</span>
      </h2>
      <div :if={@agents == []} class="text-sm text-zinc-400 dark:text-zinc-500">No agents running</div>
      <div class="space-y-2">
        <.agent_row :for={a <- @agents} data={a} />
      </div>
    </section>
    """
  end

  defp agent_row(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50 overflow-hidden">
      <div class="flex items-center justify-between px-4 py-2.5">
        <div class="flex items-center gap-3 min-w-0">
          <div class={"w-2 h-2 rounded-full flex-none #{status_color(@data.agent.status)}"}></div>
          <span class="text-sm font-medium truncate">{@data.agent.name}</span>
          <span class="text-xs text-zinc-400 dark:text-zinc-500 font-mono">{@data.agent.id |> String.slice(0..7)}</span>
          <span class="text-xs text-zinc-400">{@data.agent.status}</span>
        </div>
        <div class="flex items-center gap-1">
          <button
            :if={@data.agent.status not in [:stopped, :crashed, :destroying]}
            phx-click="restart_session" phx-value-id={@data.agent.id}
            class="text-xs font-medium text-amber-600 dark:text-amber-400 hover:bg-amber-50 dark:hover:bg-amber-500/10 rounded px-2 py-1 transition-colors"
          >
            Restart CLI
          </button>
          <button
            :if={@data.agent.status not in [:stopped, :crashed, :destroying]}
            phx-click="kill_container" phx-value-id={@data.agent.id}
            class="text-xs font-medium text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-500/10 rounded px-2 py-1 transition-colors"
          >
            Kill
          </button>
        </div>
      </div>
      <div class="grid grid-cols-1 md:grid-cols-3 gap-px bg-zinc-200 dark:bg-zinc-700/50 border-t border-zinc-200 dark:border-zinc-700/50">
        <.container_col data={@data.container} />
        <.genserver_col data={@data.beam} />
        <.agent_cli_col data={@data.cli} />
      </div>
    </div>
    """
  end

  defp container_col(%{data: nil} = assigns) do
    ~H"""
    <div class="bg-zinc-50 dark:bg-zinc-800/50 px-4 py-2">
      <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 mb-1">Docker Container</div>
      <div class="text-xs text-zinc-400">not running</div>
    </div>
    """
  end

  defp container_col(assigns) do
    ~H"""
    <div class="bg-zinc-50 dark:bg-zinc-800/50 px-4 py-2">
      <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 mb-1">Docker Container</div>
      <div class="text-xs font-mono space-y-0.5">
        <div>CPU: <span class="text-zinc-900 dark:text-zinc-100">{@data.cpu}</span></div>
        <div>Mem: <span class="text-zinc-900 dark:text-zinc-100">{@data.mem_usage}</span> <span class="text-zinc-400">({@data.mem_pct})</span></div>
        <div>PIDs: <span class="text-zinc-900 dark:text-zinc-100">{@data.pids}</span></div>
      </div>
    </div>
    """
  end

  defp genserver_col(%{data: nil} = assigns) do
    ~H"""
    <div class="bg-zinc-50 dark:bg-zinc-800/50 px-4 py-2">
      <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 mb-1">GenServer</div>
      <div class="text-xs text-zinc-400">not running</div>
    </div>
    """
  end

  defp genserver_col(assigns) do
    ~H"""
    <div class="bg-zinc-50 dark:bg-zinc-800/50 px-4 py-2">
      <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 mb-1">GenServer</div>
      <div class="text-xs font-mono space-y-0.5">
        <div>Mem: <span class="text-zinc-900 dark:text-zinc-100">{format_bytes(@data.memory)}</span></div>
        <div>Msg queue: <span class={"text-zinc-900 dark:text-zinc-100 #{if @data.message_queue_len > 100, do: "text-red-500 font-bold"}"}>{format_number(@data.message_queue_len)}</span></div>
        <div>Reductions: <span class="text-zinc-900 dark:text-zinc-100">{format_number(@data.reductions)}</span></div>
      </div>
    </div>
    """
  end

  defp agent_cli_col(%{data: nil} = assigns) do
    ~H"""
    <div class="bg-zinc-50 dark:bg-zinc-800/50 px-4 py-2">
      <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 mb-1">Claude CLI</div>
      <div class="text-xs text-zinc-400">not found</div>
    </div>
    """
  end

  defp agent_cli_col(assigns) do
    rss_high = assigns.data.rss > 1_048_576  # > 1GB in KB
    assigns = assign(assigns, :rss_high, rss_high)

    ~H"""
    <div class="bg-zinc-50 dark:bg-zinc-800/50 px-4 py-2">
      <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 mb-1">Claude CLI</div>
      <div class="text-xs font-mono space-y-0.5">
        <div>CPU: <span class="text-zinc-900 dark:text-zinc-100">{@data.cpu}%</span></div>
        <div>Mem: <span class="text-zinc-900 dark:text-zinc-100">{@data.mem}%</span></div>
        <div>RSS: <span class={if @rss_high, do: "text-red-600 dark:text-red-400 font-bold", else: "text-zinc-900 dark:text-zinc-100"}>{format_rss(@data.rss)}</span></div>
        <div>PID: <span class="text-zinc-900 dark:text-zinc-100">{@data.pid}</span></div>
      </div>
    </div>
    """
  end

  # --- Service Containers ---

  defp service_containers_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">
        Service Containers <span class="text-zinc-400 font-normal">({length(@containers)})</span>
      </h2>
      <div :if={@containers == []} class="text-sm text-zinc-400 dark:text-zinc-500">No service containers</div>
      <div :if={@containers != []} class="rounded-lg border border-zinc-200 dark:border-zinc-700/80 overflow-hidden">
        <table class="w-full text-xs">
          <thead>
            <tr class="bg-zinc-100 dark:bg-zinc-800 text-zinc-500 dark:text-zinc-400 text-left">
              <th class="px-3 py-2 font-medium">Status</th>
              <th class="px-3 py-2 font-medium">Container</th>
              <th class="px-3 py-2 font-medium">CPU</th>
              <th class="px-3 py-2 font-medium">Memory</th>
              <th class="px-3 py-2 font-medium">PIDs</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={c <- @containers} class="border-t border-zinc-200 dark:border-zinc-700/50">
              <td class="px-3 py-2">
                <div class={"w-2 h-2 rounded-full #{if c.running, do: "bg-green-500", else: "bg-red-500"}"}></div>
              </td>
              <td class="px-3 py-2 font-mono">{c.name}</td>
              <td class="px-3 py-2 font-mono">{if c.stats, do: c.stats.cpu, else: "-"}</td>
              <td class="px-3 py-2 font-mono">{if c.stats, do: c.stats.mem_usage, else: "-"}</td>
              <td class="px-3 py-2 font-mono">{if c.stats, do: c.stats.pids, else: "-"}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  # --- All Claude CLI Processes ---

  defp cli_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">
        All Claude CLI Processes <span class="text-zinc-400 font-normal">({length(@processes)})</span>
      </h2>
      <div :if={@processes == []} class="text-sm text-zinc-400 dark:text-zinc-500">No claude processes found</div>
      <div :if={@processes != []} class="rounded-lg border border-zinc-200 dark:border-zinc-700/80 overflow-hidden">
        <table class="w-full text-xs">
          <thead>
            <tr class="bg-zinc-100 dark:bg-zinc-800 text-zinc-500 dark:text-zinc-400 text-left">
              <th class="px-3 py-2 font-medium">PID</th>
              <th class="px-3 py-2 font-medium">CPU %</th>
              <th class="px-3 py-2 font-medium">MEM %</th>
              <th class="px-3 py-2 font-medium">RSS</th>
              <th class="px-3 py-2 font-medium">Command</th>
              <th class="px-3 py-2 font-medium w-16"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={proc <- @processes} class="border-t border-zinc-200 dark:border-zinc-700/50">
              <td class="px-3 py-2 font-mono">{proc.pid}</td>
              <td class="px-3 py-2 font-mono">{proc.cpu}%</td>
              <td class="px-3 py-2 font-mono">{proc.mem}%</td>
              <td class="px-3 py-2 font-mono">{format_rss(proc.rss)}</td>
              <td class="px-3 py-2 font-mono truncate max-w-md" title={proc.command}>{proc.command |> String.slice(0..120)}</td>
              <td class="px-3 py-2">
                <button phx-click="kill_process" phx-value-pid={proc.pid}
                  class="text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-500/10 rounded px-1.5 py-0.5 font-medium transition-colors">
                  kill -9
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  # --- Recent Logs ---

  defp log_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-sm font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400 mb-3">
        Recent Logs <span class="text-zinc-400 font-normal">(last 50)</span>
      </h2>
      <div class="rounded-lg border border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50 overflow-hidden max-h-96 overflow-y-auto">
        <div class="px-4 py-3 text-xs font-mono text-zinc-600 dark:text-zinc-400 space-y-0.5">
          <div :for={entry <- @logs}>
            <span class={log_level_class(entry.level)}>[{entry.level}]</span>
            <span>{entry.message}</span>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp log_level_class(:error), do: "text-red-500 font-semibold"
  defp log_level_class(:warning), do: "text-amber-500"
  defp log_level_class(:info), do: "text-blue-400"
  defp log_level_class(:debug), do: "text-zinc-500"
  defp log_level_class(_), do: "text-zinc-400"

  defp status_color(:idle), do: "bg-green-500"
  defp status_color(:thinking), do: "bg-amber-400 animate-pulse"
  defp status_color(:stopped), do: "bg-zinc-400"
  defp status_color(:crashed), do: "bg-red-500"
  defp status_color(:destroying), do: "bg-red-400 animate-pulse"
  defp status_color(_), do: "bg-zinc-400"
end
