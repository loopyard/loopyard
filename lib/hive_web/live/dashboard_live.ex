defmodule HiveWeb.DashboardLive do
  use HiveWeb, :live_view

  alias Hive.Agent, as: HiveAgent

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      HiveAgent.subscribe()
    end

    agents = HiveAgent.list_agents()

    {:ok,
     socket
     |> assign(:agents, agents)
     |> assign(:selected_agent_id, nil)
     |> assign(:selected_agent, nil)
     |> assign(:show_new_form, false)
     |> assign(:new_name, "")
     |> assign(:new_working_dir, File.cwd!())}
  end

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket) do
    if socket.assigns.selected_agent_id do
      Phoenix.PubSub.unsubscribe(Hive.PubSub, "agent:#{socket.assigns.selected_agent_id}")
    end

    HiveAgent.subscribe(id)
    agent = HiveAgent.get_state(id)

    {:noreply,
     socket
     |> assign(:selected_agent_id, id)
     |> assign(:selected_agent, agent)
     |> push_event("init_terminal", %{output: agent.output})}
  end

  @impl true
  def handle_event("toggle_new_form", _params, socket) do
    {:noreply, assign(socket, :show_new_form, !socket.assigns.show_new_form)}
  end

  @impl true
  def handle_event("spawn_agent", params, socket) do
    id = generate_id()

    opts = [
      id: id,
      name: Map.get(params, "name", "") |> then(fn n -> if n == "", do: "Agent #{String.slice(id, 0..5)}", else: n end),
      working_dir: Map.get(params, "working_dir", File.cwd!()),
      started_by: "browser"
    ]

    case Hive.AgentSupervisor.start_agent(opts) do
      {:ok, _pid} ->
        {:noreply,
         socket
         |> assign(:show_new_form, false)
         |> assign(:new_name, "")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("stop_agent", %{"id" => id}, socket) do
    HiveAgent.stop_agent(id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("kill_agent", %{"id" => id}, socket) do
    HiveAgent.kill_agent(id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("terminal_input", %{"data" => data}, socket) do
    if socket.assigns.selected_agent_id do
      HiveAgent.send_raw(socket.assigns.selected_agent_id, data)
    end

    {:noreply, socket}
  end

  # PubSub handlers
  @impl true
  def handle_info({:agent_started, _}, socket) do
    {:noreply, assign(socket, :agents, HiveAgent.list_agents())}
  end

  @impl true
  def handle_info({:agent_stopped, _}, socket) do
    agents = HiveAgent.list_agents()
    selected = if socket.assigns.selected_agent_id do
      Enum.find(agents, &(&1.id == socket.assigns.selected_agent_id))
    end
    {:noreply, socket |> assign(:agents, agents) |> assign(:selected_agent, selected)}
  end

  @impl true
  def handle_info({:agent_output, id, data}, socket) do
    if id == socket.assigns.selected_agent_id do
      {:noreply, push_event(socket, "terminal_data", %{data: data})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:agent_exited, id, _code}, socket) do
    agents = HiveAgent.list_agents()
    selected = if id == socket.assigns.selected_agent_id do
      Enum.find(agents, &(&1.id == id))
    else
      socket.assigns.selected_agent
    end
    {:noreply, socket |> assign(:agents, agents) |> assign(:selected_agent, selected)}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.hex_encode32(case: :lower, padding: false) |> String.slice(0..15)
  end

  defp format_status(:running), do: "Running"
  defp format_status(:stopping), do: "Stopping"
  defp format_status({:exited, 0}), do: "Done"
  defp format_status({:exited, _}), do: "Exited"
  defp format_status(:stopped), do: "Stopped"
  defp format_status(_), do: "Unknown"

  defp status_color(:running), do: "text-green-600 dark:text-green-400"
  defp status_color({:exited, 0}), do: "text-zinc-400 dark:text-zinc-500"
  defp status_color({:exited, _}), do: "text-red-500 dark:text-red-400"
  defp status_color(_), do: "text-zinc-400 dark:text-zinc-500"

  defp status_bg(:running), do: "bg-green-500"
  defp status_bg(:stopping), do: "bg-amber-500"
  defp status_bg({:exited, 0}), do: "bg-zinc-400 dark:bg-zinc-500"
  defp status_bg({:exited, _}), do: "bg-red-500"
  defp status_bg(_), do: "bg-zinc-400 dark:bg-zinc-500"

  defp alive?(:running), do: true
  defp alive?(:stopping), do: true
  defp alive?(_), do: false

  defp time_ago(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)
    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  defp shorten_path(path) do
    home = System.user_home!()
    String.replace_prefix(path, home, "~")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100">
      <%!-- Header --%>
      <header class="flex-none h-14 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center justify-between px-5">
        <div class="flex items-center gap-3">
          <h1 class="text-lg font-semibold tracking-tight">Hive</h1>
          <span class="text-sm text-zinc-400 dark:text-zinc-500">{length(@agents)} agent{if length(@agents) != 1, do: "s"}</span>
        </div>
        <button
          phx-click="toggle_new_form"
          class="inline-flex items-center gap-1.5 rounded-lg bg-zinc-900 dark:bg-zinc-100 px-3.5 py-1.5 text-sm font-medium text-white dark:text-zinc-900
                 hover:bg-zinc-700 dark:hover:bg-zinc-300 transition-colors"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
            <path d="M8.75 3.75a.75.75 0 0 0-1.5 0v3.5h-3.5a.75.75 0 0 0 0 1.5h3.5v3.5a.75.75 0 0 0 1.5 0v-3.5h3.5a.75.75 0 0 0 0-1.5h-3.5v-3.5Z" />
          </svg>
          New Agent
        </button>
      </header>

      <div class="flex-1 flex min-h-0">
        <%!-- Sidebar --%>
        <aside class="w-80 flex-none border-r border-zinc-200 dark:border-zinc-700/80 flex flex-col bg-zinc-50 dark:bg-zinc-900/50">
          <%!-- New agent form --%>
          <div :if={@show_new_form} class="p-4 border-b border-zinc-200 dark:border-zinc-700/80 bg-white dark:bg-zinc-800/50">
            <form phx-submit="spawn_agent" class="space-y-3">
              <div>
                <label class="block text-xs font-medium text-zinc-500 dark:text-zinc-400 mb-1">Name</label>
                <input
                  type="text"
                  name="name"
                  value={@new_name}
                  placeholder="e.g. Fix auth bug"
                  autocomplete="off"
                  class="w-full rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-2 text-sm
                         text-zinc-900 dark:text-zinc-100
                         placeholder:text-zinc-400 dark:placeholder:text-zinc-500
                         focus:outline-none focus:ring-2 focus:ring-zinc-900/10 dark:focus:ring-zinc-400/20 focus:border-zinc-400 dark:focus:border-zinc-500"
                />
              </div>
              <div>
                <label class="block text-xs font-medium text-zinc-500 dark:text-zinc-400 mb-1">Working Directory</label>
                <input
                  type="text"
                  name="working_dir"
                  value={@new_working_dir}
                  class="w-full rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-2 text-sm font-mono
                         text-zinc-600 dark:text-zinc-300
                         focus:outline-none focus:ring-2 focus:ring-zinc-900/10 dark:focus:ring-zinc-400/20 focus:border-zinc-400 dark:focus:border-zinc-500"
                />
              </div>
              <div class="flex gap-2 pt-1">
                <button
                  type="submit"
                  class="flex-1 rounded-lg bg-zinc-900 dark:bg-zinc-100 px-3 py-2 text-sm font-medium text-white dark:text-zinc-900
                         hover:bg-zinc-700 dark:hover:bg-zinc-300 transition-colors"
                >
                  Launch
                </button>
                <button
                  type="button"
                  phx-click="toggle_new_form"
                  class="rounded-lg px-3 py-2 text-sm text-zinc-500 dark:text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200
                         hover:bg-zinc-100 dark:hover:bg-zinc-700 transition-colors"
                >
                  Cancel
                </button>
              </div>
            </form>
          </div>

          <%!-- Agent list --%>
          <div class="flex-1 overflow-y-auto">
            <div :if={@agents == []} class="flex flex-col items-center justify-center h-full px-8 text-center">
              <div class="w-12 h-12 rounded-full bg-zinc-100 dark:bg-zinc-800 flex items-center justify-center mb-3">
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5 text-zinc-400 dark:text-zinc-500">
                  <path d="M10 5a3 3 0 1 1-3 3 3 3 0 0 1 3-3Zm6.5 12.5a6.5 6.5 0 0 0-13 0h13Z" />
                </svg>
              </div>
              <p class="text-sm text-zinc-500 dark:text-zinc-400">No agents yet</p>
              <p class="text-xs text-zinc-400 dark:text-zinc-500 mt-1">Click "New Agent" to get started</p>
            </div>

            <div :for={agent <- @agents}>
              <button
                phx-click="select_agent"
                phx-value-id={agent.id}
                class={"w-full text-left px-4 py-3 border-b border-zinc-200/80 dark:border-zinc-700/50 transition-colors
                       #{if @selected_agent_id == agent.id, do: "bg-white dark:bg-zinc-800 shadow-sm", else: "hover:bg-white/60 dark:hover:bg-zinc-800/40"}"}
              >
                <div class="flex items-center justify-between">
                  <div class="flex items-center gap-2.5 min-w-0">
                    <div class={"w-2 h-2 rounded-full flex-none #{status_bg(agent.status)}"}></div>
                    <span class="text-sm font-medium truncate">{agent.name}</span>
                  </div>
                  <span class="text-xs text-zinc-400 dark:text-zinc-500 flex-none ml-2">{time_ago(agent.started_at)}</span>
                </div>
                <div class="mt-1 ml-[18px] flex items-center gap-2">
                  <span class="text-xs text-zinc-400 dark:text-zinc-500 font-mono truncate">{shorten_path(agent.working_dir)}</span>
                  <span class="text-zinc-300 dark:text-zinc-600">·</span>
                  <span class={"text-xs #{status_color(agent.status)}"}>{format_status(agent.status)}</span>
                </div>
              </button>
            </div>
          </div>
        </aside>

        <%!-- Main panel --%>
        <main class="flex-1 flex flex-col min-w-0 bg-white dark:bg-zinc-900">
          <%!-- Empty state --%>
          <div :if={!@selected_agent} class="flex-1 flex items-center justify-center">
            <div class="text-center">
              <div class="w-16 h-16 rounded-2xl bg-zinc-100 dark:bg-zinc-800 flex items-center justify-center mx-auto mb-4">
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="w-7 h-7 text-zinc-300 dark:text-zinc-600">
                  <path fill-rule="evenodd" d="M4.848 2.771A49.144 49.144 0 0 1 12 2.25c2.43 0 4.817.178 7.152.52 1.978.29 3.348 2.024 3.348 3.97v6.02c0 1.946-1.37 3.68-3.348 3.97a48.901 48.901 0 0 1-3.476.383.39.39 0 0 0-.297.17l-2.755 4.133a.75.75 0 0 1-1.248 0l-2.755-4.133a.39.39 0 0 0-.297-.17 48.9 48.9 0 0 1-3.476-.384c-1.978-.29-3.348-2.024-3.348-3.97V6.741c0-1.946 1.37-3.68 3.348-3.97Z" clip-rule="evenodd" />
                </svg>
              </div>
              <p class="text-sm text-zinc-400 dark:text-zinc-500">Select an agent to view its terminal</p>
            </div>
          </div>

          <%!-- Agent view --%>
          <div :if={@selected_agent} class="flex-1 flex flex-col min-h-0">
            <%!-- Agent header --%>
            <div class="flex-none flex items-center justify-between px-5 h-12 border-b border-zinc-200 dark:border-zinc-700/80">
              <div class="flex items-center gap-3">
                <div class={"w-2 h-2 rounded-full #{status_bg(@selected_agent.status)}"}></div>
                <span class="text-sm font-semibold">{@selected_agent.name}</span>
                <span class="text-xs text-zinc-400 dark:text-zinc-500 font-mono">{shorten_path(@selected_agent.working_dir)}</span>
                <span :if={@selected_agent.os_pid} class="text-xs text-zinc-400 dark:text-zinc-600 font-mono">
                  PID {@selected_agent.os_pid}
                </span>
              </div>
              <div class="flex items-center gap-3">
                <span class={"text-xs font-medium #{status_color(@selected_agent.status)}"}>{format_status(@selected_agent.status)}</span>
                <button
                  :if={alive?(@selected_agent.status)}
                  phx-click="kill_agent"
                  phx-value-id={@selected_agent.id}
                  data-confirm="Kill this agent? (SIGKILL)"
                  class="rounded-md px-2.5 py-1 text-xs font-medium text-red-600 dark:text-red-400
                         hover:bg-red-50 dark:hover:bg-red-500/10 transition-colors"
                >
                  Kill
                </button>
              </div>
            </div>

            <%!-- Terminal (handles keyboard input directly) --%>
            <div
              id="terminal-container"
              phx-hook="Terminal"
              phx-update="ignore"
              class="flex-1 min-h-0"
            >
            </div>
          </div>
        </main>
      </div>
    </div>
    """
  end
end
