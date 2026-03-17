defmodule HiveWeb.DashboardLive do
  use HiveWeb, :live_view

  alias Hive.Agent, as: HiveAgent
  alias HiveWeb.Presence

  @default_templates [
    %{name: "General Assistant", working_dir: "", description: "General-purpose Claude agent"},
    %{name: "Code Review", working_dir: "", description: "Review code in a project"},
    %{name: "Bug Fix", working_dir: "", description: "Debug and fix issues"}
  ]

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
     |> assign(:show_templates, false)
     |> assign(:show_sidebar, false)
     |> assign(:new_name, "")
     |> assign(:new_working_dir, File.cwd!())
     |> assign(:viewer_counts, build_viewer_counts(agents))
     |> assign(:templates, @default_templates)}
  end

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket) do
    socket_id = socket.id

    # Untrack and unsubscribe from previous agent
    if prev = socket.assigns.selected_agent_id do
      Presence.untrack_viewer(self(), prev, socket_id)
      Presence.unsubscribe(prev)
      HiveAgent.unsubscribe(prev)
    end

    # Subscribe and track new agent
    HiveAgent.subscribe(id)
    Presence.subscribe(id)
    Presence.track_viewer(self(), id, socket_id)

    agent = HiveAgent.get_state(id)

    {:noreply,
     socket
     |> assign(:selected_agent_id, id)
     |> assign(:selected_agent, agent)
     |> assign(:show_sidebar, false)
     |> update_viewer_count(id)
     |> push_event("init_terminal", %{output: agent.output, cols: agent.cols, rows: agent.rows})}
  end

  @impl true
  def handle_event("toggle_new_form", _params, socket) do
    {:noreply, assign(socket, show_new_form: !socket.assigns.show_new_form, show_templates: false)}
  end

  @impl true
  def handle_event("toggle_templates", _params, socket) do
    {:noreply, assign(socket, show_templates: !socket.assigns.show_templates, show_new_form: false)}
  end

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :show_sidebar, !socket.assigns.show_sidebar)}
  end

  @impl true
  def handle_event("hide_sidebar", _params, socket) do
    {:noreply, assign(socket, :show_sidebar, false)}
  end

  @impl true
  def handle_event("use_template", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    template = Enum.at(socket.assigns.templates, index)

    working_dir = if template.working_dir == "", do: File.cwd!(), else: template.working_dir

    {:noreply,
     socket
     |> assign(:show_templates, false)
     |> assign(:show_new_form, true)
     |> assign(:new_name, template.name)
     |> assign(:new_working_dir, working_dir)}
  end

  @impl true
  def handle_event("spawn_agent", params, socket) do
    working_dir = Map.get(params, "working_dir", File.cwd!())

    case HiveAgent.validate_working_dir(working_dir) do
      :ok ->
        id = generate_id()

        opts = [
          id: id,
          name:
            Map.get(params, "name", "")
            |> then(fn n -> if n == "", do: "Agent #{String.slice(id, 0..5)}", else: n end),
          working_dir: working_dir,
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

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Invalid working directory: #{reason}")}
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
    agents = HiveAgent.list_agents()
    {:noreply, socket |> assign(:agents, agents) |> assign(:viewer_counts, build_viewer_counts(agents))}
  end

  @impl true
  def handle_info({:agent_stopped, _}, socket) do
    agents = HiveAgent.list_agents()

    selected =
      if socket.assigns.selected_agent_id do
        Enum.find(agents, &(&1.id == socket.assigns.selected_agent_id))
      end

    {:noreply,
     socket
     |> assign(:agents, agents)
     |> assign(:selected_agent, selected)
     |> assign(:viewer_counts, build_viewer_counts(agents))}
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

    selected =
      if id == socket.assigns.selected_agent_id do
        Enum.find(agents, &(&1.id == id))
      else
        socket.assigns.selected_agent
      end

    {:noreply, socket |> assign(:agents, agents) |> assign(:selected_agent, selected)}
  end

  @impl true
  def handle_info({:agent_resized, id, cols, rows}, socket) do
    if id == socket.assigns.selected_agent_id do
      {:noreply, push_event(socket, "terminal_resize", %{cols: cols, rows: rows})}
    else
      {:noreply, socket}
    end
  end

  # Presence diff updates
  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    agents = socket.assigns.agents
    {:noreply, assign(socket, :viewer_counts, build_viewer_counts(agents))}
  end

  # --- Helpers ---

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp build_viewer_counts(agents) do
    Map.new(agents, fn agent ->
      {agent.id, Presence.viewer_count(agent.id)}
    end)
  end

  defp update_viewer_count(socket, agent_id) do
    counts = Map.put(socket.assigns.viewer_counts, agent_id, Presence.viewer_count(agent_id))
    assign(socket, :viewer_counts, counts)
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

  # --- Components ---

  defp agent_list(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto">
      <div :if={@agents == []} class="flex flex-col items-center justify-center h-full px-8 text-center">
        <div class="w-12 h-12 rounded-full bg-zinc-100 dark:bg-zinc-800 flex items-center justify-center mb-3">
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5 text-zinc-400 dark:text-zinc-500">
            <path d="M10 5a3 3 0 1 1-3 3 3 3 0 0 1 3-3Zm6.5 12.5a6.5 6.5 0 0 0-13 0h13Z" />
          </svg>
        </div>
        <p class="text-sm text-zinc-500 dark:text-zinc-400">No agents yet</p>
        <p class="text-xs text-zinc-400 dark:text-zinc-500 mt-1">Tap "New Agent" to get started</p>
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
            <div class="flex items-center gap-2 flex-none ml-2">
              <.viewer_badge count={Map.get(@viewer_counts, agent.id, 0)} />
              <span class="text-xs text-zinc-400 dark:text-zinc-500">{time_ago(agent.started_at)}</span>
            </div>
          </div>
          <div class="mt-1 ml-[18px] flex items-center gap-2">
            <span class="text-xs text-zinc-400 dark:text-zinc-500 font-mono truncate">{shorten_path(agent.working_dir)}</span>
            <span class="text-zinc-300 dark:text-zinc-600">&middot;</span>
            <span class={"text-xs #{status_color(agent.status)}"}>{format_status(agent.status)}</span>
          </div>
        </button>
      </div>
    </div>
    """
  end

  defp viewer_badge(assigns) do
    ~H"""
    <span :if={@count > 0} class="inline-flex items-center gap-1 text-xs text-zinc-400 dark:text-zinc-500" title={"#{@count} viewer#{if @count != 1, do: "s"}"}>
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3 h-3">
        <path d="M8 8a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM12.735 14c.618 0 1.093-.561.872-1.139a6.002 6.002 0 0 0-11.215 0c-.22.578.254 1.139.872 1.139h9.47Z" />
      </svg>
      {@count}
    </span>
    """
  end

  defp new_agent_form(assigns) do
    ~H"""
    <div class="p-4 border-b border-zinc-200 dark:border-zinc-700/80 bg-white dark:bg-zinc-800/50">
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
    """
  end

  defp template_picker(assigns) do
    ~H"""
    <div class="p-4 border-b border-zinc-200 dark:border-zinc-700/80 bg-white dark:bg-zinc-800/50">
      <p class="text-xs font-medium text-zinc-500 dark:text-zinc-400 mb-2">Quick Start Templates</p>
      <div class="space-y-1.5">
        <button
          :for={{template, index} <- Enum.with_index(@templates)}
          phx-click="use_template"
          phx-value-index={index}
          class="w-full text-left rounded-lg px-3 py-2.5 hover:bg-zinc-100 dark:hover:bg-zinc-700/50 transition-colors group"
        >
          <div class="text-sm font-medium text-zinc-700 dark:text-zinc-200 group-hover:text-zinc-900 dark:group-hover:text-white">
            {template.name}
          </div>
          <div class="text-xs text-zinc-400 dark:text-zinc-500 mt-0.5">{template.description}</div>
        </button>
      </div>
      <button
        phx-click="toggle_templates"
        class="mt-2 w-full text-center text-xs text-zinc-400 dark:text-zinc-500 hover:text-zinc-600 dark:hover:text-zinc-300"
      >
        Cancel
      </button>
    </div>
    """
  end

  defp terminal_panel(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col min-h-0">
      <%!-- Agent header --%>
      <div class="flex-none flex items-center justify-between px-3 md:px-5 h-12 border-b border-zinc-200 dark:border-zinc-700/80">
        <div class="flex items-center gap-2 md:gap-3 min-w-0">
          <%!-- Back button (mobile only) --%>
          <button
            phx-click="toggle_sidebar"
            class="md:hidden rounded-md p-1 text-zinc-500 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800 -ml-1"
          >
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5">
              <path fill-rule="evenodd" d="M11.78 5.22a.75.75 0 0 1 0 1.06L8.06 10l3.72 3.72a.75.75 0 1 1-1.06 1.06l-4.25-4.25a.75.75 0 0 1 0-1.06l4.25-4.25a.75.75 0 0 1 1.06 0Z" clip-rule="evenodd" />
            </svg>
          </button>
          <div class={"w-2 h-2 rounded-full flex-none #{status_bg(@agent.status)}"}></div>
          <span class="text-sm font-semibold truncate">{@agent.name}</span>
          <span class="hidden sm:inline text-xs text-zinc-400 dark:text-zinc-500 font-mono truncate">{shorten_path(@agent.working_dir)}</span>
          <span :if={@agent.os_pid} class="hidden lg:inline text-xs text-zinc-400 dark:text-zinc-600 font-mono">
            PID {@agent.os_pid}
          </span>
          <.viewer_badge count={@viewer_count} />
        </div>
        <div class="flex items-center gap-2 md:gap-3 flex-none">
          <span class={"text-xs font-medium #{status_color(@agent.status)}"}>{format_status(@agent.status)}</span>
          <button
            :if={alive?(@agent.status)}
            phx-click="stop_agent"
            phx-value-id={@agent.id}
            class="rounded-md px-2 py-1 text-xs font-medium text-amber-600 dark:text-amber-400
                   hover:bg-amber-50 dark:hover:bg-amber-500/10 transition-colors"
          >
            Stop
          </button>
          <button
            :if={alive?(@agent.status)}
            phx-click="kill_agent"
            phx-value-id={@agent.id}
            data-confirm="Kill this agent? (SIGKILL)"
            class="rounded-md px-2 py-1 text-xs font-medium text-red-600 dark:text-red-400
                   hover:bg-red-50 dark:hover:bg-red-500/10 transition-colors"
          >
            Kill
          </button>
        </div>
      </div>

      <%!-- Terminal --%>
      <div
        id="terminal-container"
        phx-hook="Terminal"
        phx-update="ignore"
        class="flex-1 min-h-0"
      >
      </div>
    </div>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center p-8">
      <div class="text-center">
        <%!-- Mobile: show sidebar button --%>
        <button
          phx-click="toggle_sidebar"
          class="md:hidden mb-6 inline-flex items-center gap-2 rounded-lg bg-zinc-100 dark:bg-zinc-800 px-4 py-2.5 text-sm font-medium
                 text-zinc-700 dark:text-zinc-200 hover:bg-zinc-200 dark:hover:bg-zinc-700 transition-colors"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5">
            <path fill-rule="evenodd" d="M2 4.75A.75.75 0 0 1 2.75 4h14.5a.75.75 0 0 1 0 1.5H2.75A.75.75 0 0 1 2 4.75Zm0 10.5a.75.75 0 0 1 .75-.75h7.5a.75.75 0 0 1 0 1.5h-7.5a.75.75 0 0 1-.75-.75ZM2 10a.75.75 0 0 1 .75-.75h14.5a.75.75 0 0 1 0 1.5H2.75A.75.75 0 0 1 2 10Z" clip-rule="evenodd" />
          </svg>
          View Agents
        </button>
        <div class="w-16 h-16 rounded-2xl bg-zinc-100 dark:bg-zinc-800 flex items-center justify-center mx-auto mb-4">
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="w-7 h-7 text-zinc-300 dark:text-zinc-600">
            <path fill-rule="evenodd" d="M4.848 2.771A49.144 49.144 0 0 1 12 2.25c2.43 0 4.817.178 7.152.52 1.978.29 3.348 2.024 3.348 3.97v6.02c0 1.946-1.37 3.68-3.348 3.97a48.901 48.901 0 0 1-3.476.383.39.39 0 0 0-.297.17l-2.755 4.133a.75.75 0 0 1-1.248 0l-2.755-4.133a.39.39 0 0 0-.297-.17 48.9 48.9 0 0 1-3.476-.384c-1.978-.29-3.348-2.024-3.348-3.97V6.741c0-1.946 1.37-3.68 3.348-3.97Z" clip-rule="evenodd" />
          </svg>
        </div>
        <p class="text-sm text-zinc-400 dark:text-zinc-500">Select an agent to view its terminal</p>
      </div>
    </div>
    """
  end

  defp sidebar_content(assigns) do
    ~H"""
    <.new_agent_form :if={@show_new_form} new_name={@new_name} new_working_dir={@new_working_dir} />
    <.template_picker :if={@show_templates} templates={@templates} />
    <.agent_list agents={@agents} selected_agent_id={@selected_agent_id} viewer_counts={@viewer_counts} />
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen flex flex-col bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100 safe-area-top">
      <%!-- Connection status banner --%>
      <div id="connection-status" phx-hook="ConnectionStatus" class="connection-banner hidden">
        Reconnecting...
      </div>

      <%!-- Header --%>
      <header class="flex-none h-14 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center justify-between px-3 md:px-5">
        <div class="flex items-center gap-3">
          <%!-- Hamburger (mobile only, when agent is NOT selected) --%>
          <button
            :if={!@selected_agent}
            phx-click="toggle_sidebar"
            class="md:hidden rounded-md p-1 text-zinc-500 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800"
          >
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5">
              <path fill-rule="evenodd" d="M2 4.75A.75.75 0 0 1 2.75 4h14.5a.75.75 0 0 1 0 1.5H2.75A.75.75 0 0 1 2 4.75Zm0 10.5a.75.75 0 0 1 .75-.75h7.5a.75.75 0 0 1 0 1.5h-7.5a.75.75 0 0 1-.75-.75ZM2 10a.75.75 0 0 1 .75-.75h14.5a.75.75 0 0 1 0 1.5H2.75A.75.75 0 0 1 2 10Z" clip-rule="evenodd" />
            </svg>
          </button>
          <h1 class="text-lg font-semibold tracking-tight">Hive</h1>
          <span class="text-sm text-zinc-400 dark:text-zinc-500">{length(@agents)} agent{if length(@agents) != 1, do: "s"}</span>
        </div>
        <div class="flex items-center gap-1.5 md:gap-2">
          <button
            phx-click="toggle_templates"
            class="hidden sm:inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium
                   text-zinc-600 dark:text-zinc-300
                   hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
          >
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
              <path d="M3.5 2A1.5 1.5 0 0 0 2 3.5v2A1.5 1.5 0 0 0 3.5 7h2A1.5 1.5 0 0 0 7 5.5v-2A1.5 1.5 0 0 0 5.5 2h-2Zm7 0A1.5 1.5 0 0 0 9 3.5v2A1.5 1.5 0 0 0 10.5 7h2A1.5 1.5 0 0 0 14 5.5v-2A1.5 1.5 0 0 0 12.5 2h-2Zm-7 7A1.5 1.5 0 0 0 2 10.5v2A1.5 1.5 0 0 0 3.5 14h2A1.5 1.5 0 0 0 7 12.5v-2A1.5 1.5 0 0 0 5.5 9h-2Zm7 0A1.5 1.5 0 0 0 9 10.5v2a1.5 1.5 0 0 0 1.5 1.5h2a1.5 1.5 0 0 0 1.5-1.5v-2A1.5 1.5 0 0 0 12.5 9h-2Z" />
            </svg>
            Templates
          </button>
          <button
            phx-click="toggle_new_form"
            class="inline-flex items-center gap-1.5 rounded-lg bg-zinc-900 dark:bg-zinc-100 px-3 md:px-3.5 py-1.5 text-sm font-medium text-white dark:text-zinc-900
                   hover:bg-zinc-700 dark:hover:bg-zinc-300 transition-colors"
          >
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
              <path d="M8.75 3.75a.75.75 0 0 0-1.5 0v3.5h-3.5a.75.75 0 0 0 0 1.5h3.5v3.5a.75.75 0 0 0 1.5 0v-3.5h3.5a.75.75 0 0 0 0-1.5h-3.5v-3.5Z" />
            </svg>
            <span class="hidden sm:inline">New Agent</span>
            <span class="sm:hidden">New</span>
          </button>
        </div>
      </header>

      <div class="flex-1 flex min-h-0">
        <%!-- Desktop sidebar (always visible on md+) --%>
        <aside class="hidden md:flex w-80 flex-none border-r border-zinc-200 dark:border-zinc-700/80 flex-col bg-zinc-50 dark:bg-zinc-900/50">
          <.sidebar_content
            show_new_form={@show_new_form}
            show_templates={@show_templates}
            new_name={@new_name}
            new_working_dir={@new_working_dir}
            templates={@templates}
            agents={@agents}
            selected_agent_id={@selected_agent_id}
            viewer_counts={@viewer_counts}
          />
        </aside>

        <%!-- Mobile sidebar overlay --%>
        <div :if={@show_sidebar} class="md:hidden sidebar-overlay" phx-click="hide_sidebar"></div>
        <aside
          :if={@show_sidebar}
          class="md:hidden sidebar-mobile flex flex-col bg-zinc-50 dark:bg-zinc-900 border-r border-zinc-200 dark:border-zinc-700/80"
        >
          <%!-- Close button --%>
          <div class="flex items-center justify-between px-4 h-12 border-b border-zinc-200 dark:border-zinc-700/80">
            <span class="text-sm font-semibold">Agents</span>
            <button
              phx-click="hide_sidebar"
              class="rounded-md p-1 text-zinc-500 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800"
            >
              <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5">
                <path d="M6.28 5.22a.75.75 0 0 0-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 1 0 1.06 1.06L10 11.06l3.72 3.72a.75.75 0 1 0 1.06-1.06L11.06 10l3.72-3.72a.75.75 0 0 0-1.06-1.06L10 8.94 6.28 5.22Z" />
              </svg>
            </button>
          </div>
          <.sidebar_content
            show_new_form={@show_new_form}
            show_templates={@show_templates}
            new_name={@new_name}
            new_working_dir={@new_working_dir}
            templates={@templates}
            agents={@agents}
            selected_agent_id={@selected_agent_id}
            viewer_counts={@viewer_counts}
          />
        </aside>

        <%!-- Main panel --%>
        <main class="flex-1 flex flex-col min-w-0 bg-white dark:bg-zinc-900">
          <.empty_state :if={!@selected_agent} />
          <.terminal_panel
            :if={@selected_agent}
            agent={@selected_agent}
            viewer_count={Map.get(@viewer_counts, @selected_agent_id, 0)}
          />
        </main>
      </div>
    </div>
    """
  end
end
