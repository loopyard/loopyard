defmodule HiveWeb.OpsLive do
  @moduledoc """
  Operations dashboard. Shows container status, running services,
  logs, and ports for all agents. Works on desktop and phone.
  """
  use HiveWeb, :live_view

  alias Hive.ChatAgent
  alias Hive.Tools.Container

  @refresh_interval 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ChatAgent.subscribe()
      Process.send_after(self(), :refresh, @refresh_interval)
    end

    agents = ChatAgent.list_agents()

    {:ok,
     socket
     |> assign(:agents, agents)
     |> assign(:selected_id, nil)
     |> assign(:logs, "")
     |> assign(:env_info, nil)
     |> assign(:log_service, nil)
     |> assign(:log_lines, 100)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    {:noreply, load_agent_ops(socket, id)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: "/ops/#{id}")}
  end

  @impl true
  def handle_event("refresh_logs", _params, socket) do
    {:noreply, fetch_logs(socket)}
  end

  @impl true
  def handle_event("filter_service", %{"service" => service}, socket) do
    service = if service == "", do: nil, else: service
    socket = assign(socket, :log_service, service)
    {:noreply, fetch_logs(socket)}
  end

  @impl true
  def handle_event("refresh_env", _params, socket) do
    {:noreply, fetch_env(socket)}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_interval)

    socket =
      socket
      |> assign(:agents, ChatAgent.list_agents())
      |> then(fn s -> if s.assigns.selected_id, do: fetch_logs(s), else: s end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:chat_agent_started, _}, socket) do
    {:noreply, assign(socket, :agents, ChatAgent.list_agents())}
  end

  @impl true
  def handle_info({:chat_agent_stopped, _}, socket) do
    {:noreply, assign(socket, :agents, ChatAgent.list_agents())}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp load_agent_ops(socket, id) do
    socket
    |> assign(:selected_id, id)
    |> fetch_logs()
    |> fetch_env()
  end

  defp fetch_logs(socket) do
    case socket.assigns.selected_id do
      nil ->
        assign(socket, :logs, "")

      id ->
        opts = %{lines: socket.assigns.log_lines}
        opts = if socket.assigns.log_service, do: Map.put(opts, :service, socket.assigns.log_service), else: opts

        logs =
          case Container.do_logs(id, opts) do
            {:ok, output} -> output
            {:error, err} -> "Error: #{err}"
          end

        assign(socket, :logs, logs)
    end
  end

  defp fetch_env(socket) do
    case socket.assigns.selected_id do
      nil ->
        assign(socket, :env_info, nil)

      id ->
        info =
          case Container.do_inspect(id) do
            {:ok, output} -> output
            _ -> nil
          end

        assign(socket, :env_info, info)
    end
  end

  defp status_dot(:idle), do: "bg-green-500"
  defp status_dot(:thinking), do: "bg-amber-400 animate-pulse"
  defp status_dot(:stopped), do: "bg-zinc-400"
  defp status_dot(_), do: "bg-zinc-400"

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100">
      <%!-- Header --%>
      <header class="flex-none h-14 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center justify-between px-4 md:px-5">
        <div class="flex items-center gap-3">
          <a href="/" class="text-lg font-semibold tracking-tight hover:text-violet-600 transition-colors">Hive</a>
          <span class="text-sm text-zinc-400 dark:text-zinc-500">Ops</span>
        </div>
        <a href="/" class="text-sm text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors">
          Chat
        </a>
      </header>

      <div class="flex-1 flex min-h-0">
        <%!-- Sidebar: agent list --%>
        <aside class="w-60 md:w-72 flex-none border-r border-zinc-200 dark:border-zinc-700/80 overflow-y-auto bg-zinc-50 dark:bg-zinc-900/50">
          <div :if={@agents == []} class="p-4 text-sm text-zinc-400">No agents</div>
          <button
            :for={agent <- @agents}
            phx-click="select_agent"
            phx-value-id={agent.id}
            class={"w-full text-left px-4 py-3 border-b border-zinc-200/80 dark:border-zinc-700/50 transition-colors
                   #{if @selected_id == agent.id, do: "bg-white dark:bg-zinc-800", else: "hover:bg-white/60 dark:hover:bg-zinc-800/40"}"}
          >
            <div class="flex items-center gap-2">
              <div class={"w-2 h-2 rounded-full flex-none #{status_dot(agent.status)}"}></div>
              <span class="text-sm font-medium truncate">{agent.name}</span>
            </div>
            <div class="mt-0.5 ml-[18px] text-xs text-zinc-400 font-mono truncate">{agent.id}</div>
          </button>
        </aside>

        <%!-- Main panel --%>
        <main class="flex-1 flex flex-col min-w-0 overflow-hidden">
          <div :if={!@selected_id} class="flex-1 flex items-center justify-center">
            <p class="text-sm text-zinc-400">Select an agent to view its environment</p>
          </div>

          <div :if={@selected_id} class="flex-1 flex flex-col min-h-0 overflow-y-auto">
            <%!-- Environment info --%>
            <div :if={@env_info} class="border-b border-zinc-200 dark:border-zinc-700/80">
              <div class="flex items-center justify-between px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50">
                <h2 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">Environment</h2>
                <button phx-click="refresh_env" class="text-xs text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300">
                  Refresh
                </button>
              </div>
              <pre class="px-4 py-3 text-xs font-mono text-zinc-600 dark:text-zinc-400 overflow-x-auto whitespace-pre-wrap max-h-64 overflow-y-auto">{@env_info}</pre>
            </div>

            <div :if={!@env_info && @selected_id} class="border-b border-zinc-200 dark:border-zinc-700/80 px-4 py-3">
              <p class="text-sm text-zinc-400">No container running for this agent.
                <button phx-click="refresh_env" class="text-violet-500 hover:text-violet-600 underline">Check again</button>
              </p>
            </div>

            <%!-- Logs --%>
            <div class="flex-1 flex flex-col min-h-0">
              <div class="flex items-center justify-between px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50 border-b border-zinc-200 dark:border-zinc-700/80">
                <h2 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">Logs</h2>
                <div class="flex items-center gap-3">
                  <form phx-change="filter_service" class="inline">
                    <input
                      type="text"
                      name="service"
                      value={@log_service || ""}
                      placeholder="Filter by service..."
                      class="text-xs rounded border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-2 py-1 w-32
                             focus:outline-none focus:ring-1 focus:ring-violet-500/30"
                    />
                  </form>
                  <button phx-click="refresh_logs" class="text-xs text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300">
                    Refresh
                  </button>
                </div>
              </div>
              <pre class="flex-1 px-4 py-3 text-xs font-mono text-zinc-600 dark:text-zinc-400 overflow-auto whitespace-pre-wrap bg-zinc-900 dark:bg-black text-green-400 dark:text-green-400">{@logs}</pre>
            </div>
          </div>
        </main>
      </div>
    </div>
    """
  end
end
