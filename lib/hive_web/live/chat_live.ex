defmodule HiveWeb.ChatLive do
  use HiveWeb, :live_view

  alias Hive.ChatAgent

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ChatAgent.subscribe()
    end

    agents = ChatAgent.list_agents()

    {:ok,
     socket
     |> assign(:agents, agents)
     |> assign(:selected_id, nil)
     |> assign(:selected_agent, nil)
     |> assign(:messages, [])
     |> assign(:streaming_text, "")
     |> assign(:tab, :chat)
     |> assign(:container_logs, "")
     |> assign(:container_env, nil)
     |> assign(:container_log_service, nil)
     |> assign(:has_container, false)
     |> assign(:booting_agent_id, nil)
     |> assign(:booting_agent_name, nil)
     |> assign(:boot_status, "Initializing...")}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: action}} = socket) do
    tab = if action == :container, do: :container, else: :chat

    socket =
      if socket.assigns.selected_id != id do
        case select_agent(socket, id) do
          {:noreply, s} ->
            s

          :not_found ->
            # Agent truly doesn't exist — redirect
            socket
            |> put_flash(:error, "Agent not found")
            |> push_navigate(to: "/")
        end
      else
        socket
      end

    socket = assign(socket, :tab, tab)
    socket = if tab == :container, do: fetch_container_data(socket), else: socket
    {:noreply, socket}
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :new}} = socket) do
    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, :tab, :chat)}

  # --- Events ---

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket) do
    tab = socket.assigns.tab
    path = if tab == :container, do: "/chat/#{id}/container", else: "/chat/#{id}"
    {:noreply, push_patch(socket, to: path) |> push_event("focus_input", %{})}
  end

  @impl true
  def handle_event("spawn_agent", params, socket) do
    working_dir = Map.get(params, "working_dir", File.cwd!())
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    name =
      Map.get(params, "name", "")
      |> then(fn n -> if n == "", do: auto_name(), else: n end)

    agent_opts = [
      id: id,
      name: name,
      working_dir: working_dir,
      started_by: "browser",
      bind_mount: working_dir
    ]

    # Register in ETS immediately so all viewers can see the booting state
    ChatAgent.register_booting(id, name, working_dir)

    # Spawn async so the UI stays responsive during Docker setup
    Task.start(fn ->
      try do
        ChatAgent.update_boot_status(id, "Creating volumes...")
        Hive.Docker.create_volumes(id, bind_mount: working_dir)

        ChatAgent.update_boot_status(id, "Building container image...")
        case Hive.Docker.build_image(id) do
          {:ok, _} -> :ok
          {:error, reason} -> throw({:docker_failed, reason})
        end

        ChatAgent.update_boot_status(id, "Starting container...")
        case Hive.Docker.start_container(id, bind_mount: working_dir) do
          {:ok, _} -> :ok
          {:error, reason} -> throw({:docker_failed, reason})
        end

        ChatAgent.update_boot_status(id, "Connecting to Claude...")
        agent_opts = Keyword.put(agent_opts, :docker_ready, true)

        case Hive.ChatAgentSupervisor.start_agent(agent_opts) do
          {:ok, _pid} -> :ok
          {:error, reason} -> ChatAgent.boot_failed(id, reason)
        end
      catch
        {:docker_failed, reason} ->
          Hive.Docker.destroy(id)
          ChatAgent.boot_failed(id, "Docker setup failed: #{reason}")
      end
    end)

    {:noreply, push_navigate(socket, to: "/chat/#{id}")}
  end

  @impl true
  def handle_event("send_message", %{"message" => message}, socket) do
    message = String.trim(message)

    if message != "" && socket.assigns.selected_id do
      ChatAgent.send_message(socket.assigns.selected_id, message)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("stop_agent", %{"id" => id}, socket) do
    ChatAgent.stop_agent(id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("remove_agent", %{"id" => id}, socket) do
    ChatAgent.remove_agent(id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("rename_agent", %{"name" => name}, socket) do
    if socket.assigns.selected_id && String.trim(name) != "" do
      ChatAgent.rename(socket.assigns.selected_id, String.trim(name))
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab = String.to_existing_atom(tab)

    path =
      case {socket.assigns.selected_id, tab} do
        {nil, _} -> "/"
        {id, :container} -> "/chat/#{id}/container"
        {id, _} -> "/chat/#{id}"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("refresh_container", _params, socket) do
    {:noreply, fetch_container_data(socket)}
  end

  @impl true
  def handle_event("filter_container_service", %{"service" => service}, socket) do
    service = if service == "", do: nil, else: service
    socket = assign(socket, :container_log_service, service)
    {:noreply, fetch_container_data(socket)}
  end

  # --- PubSub ---

  @impl true
  def handle_info({:chat_agent_started, agent_summary}, socket) do
    socket = assign(socket, :agents, ChatAgent.list_agents())

    # If this is the agent we were waiting for, clear booting state
    if socket.assigns.booting_agent_id && agent_summary.id == socket.assigns.booting_agent_id do
      socket = assign(socket, :booting_agent_id, nil)

      # If the user is still viewing this agent, select it properly
      if socket.assigns.selected_id == agent_summary.id do
        case select_agent(socket, agent_summary.id) do
          {:noreply, s} -> {:noreply, s}
          :not_found -> {:noreply, socket}
        end
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:chat_agent_booting, summary}, socket) do
    {:noreply, assign(socket, :agents, ChatAgent.list_agents())
     |> then(fn s ->
       if s.assigns.selected_id == summary.id do
         assign(s, booting_agent_id: summary.id, booting_agent_name: summary.name, boot_status: summary[:boot_status] || "Initializing...")
       else
         s
       end
     end)}
  end

  @impl true
  def handle_info({:chat_agent_boot_status, id, status_text}, socket) do
    agents =
      Enum.map(socket.assigns.agents, fn a ->
        if a.id == id, do: Map.put(a, :boot_status, status_text), else: a
      end)

    socket = assign(socket, :agents, agents)

    socket =
      if socket.assigns.booting_agent_id == id do
        assign(socket, :boot_status, status_text)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:chat_agent_boot_failed, id, reason}, socket) do
    socket = assign(socket, :agents, ChatAgent.list_agents())

    socket =
      if socket.assigns.booting_agent_id == id || socket.assigns.selected_id == id do
        socket
        |> assign(:booting_agent_id, nil)
        |> put_flash(:error, "Failed to start agent: #{inspect(reason)}")
        |> push_navigate(to: "/")
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:chat_agent_stopped, _}, socket) do
    agents = ChatAgent.list_agents()

    selected =
      if socket.assigns.selected_id,
        do: Enum.find(agents, &(&1.id == socket.assigns.selected_id))

    {:noreply, socket |> assign(:agents, agents) |> assign(:selected_agent, selected)}
  end

  @impl true
  def handle_info({:chat_agent_removed, id}, socket) do
    socket = assign(socket, :agents, ChatAgent.list_agents())

    socket =
      if socket.assigns.selected_id == id do
        assign(socket, selected_id: nil, selected_agent: nil, messages: [])
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:chat_agent_renamed, id, new_name}, socket) do
    agents =
      Enum.map(socket.assigns.agents, fn a ->
        if a.id == id, do: %{a | name: new_name}, else: a
      end)

    socket = assign(socket, :agents, agents)

    socket =
      if id == socket.assigns.selected_id do
        selected = Enum.find(agents, &(&1.id == id))
        assign(socket, :selected_agent, selected)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:chat_agent_status_changed, id, status}, socket) do
    agents =
      Enum.map(socket.assigns.agents, fn a ->
        if a.id == id, do: %{a | status: status}, else: a
      end)

    socket = assign(socket, :agents, agents)

    socket =
      if id == socket.assigns.selected_id do
        selected = Enum.find(agents, &(&1.id == id))
        assign(socket, :selected_agent, selected)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:chat_message, id, msg}, socket) when id == socket.assigns.selected_id do
    # When a full assistant message arrives, clear streaming text (it's now in the complete message)
    socket = if msg.role == :assistant, do: assign(socket, :streaming_text, ""), else: socket

    {:noreply,
     socket
     |> assign(:messages, socket.assigns.messages ++ [msg])
     |> push_event("scroll_bottom", %{})}
  end

  @impl true
  def handle_info({:chat_text_delta, id, text}, socket) when id == socket.assigns.selected_id do
    {:noreply,
     socket
     |> assign(:streaming_text, socket.assigns.streaming_text <> text)
     |> push_event("scroll_bottom", %{})}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Private ---

  defp select_agent(socket, id) do
    if prev = socket.assigns.selected_id do
      ChatAgent.unsubscribe(prev)
    end

    case ChatAgent.get_state(id) do
      nil ->
        :not_found

      %{status: :booting} = summary ->
        # Agent is still booting — show booting screen, not chat
        agents = ChatAgent.list_agents()

        socket =
          socket
          |> assign(:agents, agents)
          |> assign(:selected_id, id)
          |> assign(:selected_agent, nil)
          |> assign(:booting_agent_id, id)
          |> assign(:booting_agent_name, summary.name)
          |> assign(:boot_status, summary[:boot_status] || "Initializing...")

        {:noreply, socket}

      agent ->
        ChatAgent.subscribe(id)
        agents = ChatAgent.list_agents()

        socket =
          socket
          |> assign(:agents, agents)
          |> assign(:selected_id, id)
          |> assign(:selected_agent, agent)
          |> assign(:messages, agent.messages)
          |> assign(:streaming_text, "")
          |> assign(:booting_agent_id, nil)

        {:noreply, socket}
    end
  end

  defp fetch_container_data(socket) do
    case socket.assigns.selected_id do
      nil ->
        socket

      id ->
        has_container = Hive.Docker.running?(id)

        if has_container do
          log_opts = %{lines: 100}
          log_opts = if socket.assigns.container_log_service, do: Map.put(log_opts, :service, socket.assigns.container_log_service), else: log_opts

          logs =
            case Hive.Tools.Container.do_logs(id, log_opts) do
              {:ok, output} -> output
              {:error, err} -> "Error: #{err}"
            end

          env =
            case Hive.Tools.Container.do_inspect(id) do
              {:ok, output} -> output
              _ -> nil
            end

          socket
          |> assign(:container_logs, logs)
          |> assign(:container_env, env)
          |> assign(:has_container, true)
        else
          socket
          |> assign(:container_logs, "")
          |> assign(:container_env, nil)
          |> assign(:has_container, false)
        end
    end
  end

  @adjectives ~w(Swift Bright Calm Deep Quick Sharp Keen Bold Clear True)
  @nouns ~w(Spark Drift Pulse Wave Bloom Forge Sage Fern Tide Mesa)

  defp auto_name do
    adj = Enum.random(@adjectives)
    noun = Enum.random(@nouns)
    "#{adj} #{noun}"
  end

  defp status_dot(:booting), do: "bg-violet-400 animate-pulse"
  defp status_dot(:idle), do: "bg-green-500"
  defp status_dot(:thinking), do: "bg-amber-400 animate-pulse"
  defp status_dot(:stopped), do: "bg-zinc-400"
  defp status_dot(:crashed), do: "bg-red-500"
  defp status_dot(:destroying), do: "bg-red-400 animate-pulse"
  defp status_dot(_), do: "bg-zinc-400"

  defp shorten_path(path) do
    home = System.user_home!()
    String.replace_prefix(path, home, "~")
  end

  defp time_ago(nil), do: ""

  defp time_ago(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> "#{div(diff, 3600)}h ago"
    end
  end

  # Human-readable tool summaries
  defp tool_summary(tool_name, input) when is_map(input) do
    clean_name = tool_name |> String.replace(~r/^mcp__[\w-]+__/, "")

    case {clean_name, input} do
      {"Read", %{"file_path" => path}} -> "Read #{shorten_path(path)}"
      {"Write", %{"file_path" => path}} -> "Wrote #{shorten_path(path)}"
      {"Edit", %{"file_path" => path}} -> "Edited #{shorten_path(path)}"
      {"Bash", %{"command" => cmd}} -> "$ #{String.slice(cmd, 0..80)}"
      {"Grep", %{"pattern" => pat}} -> "Searched for \"#{pat}\""
      {"Glob", %{"pattern" => pat}} -> "Found files matching #{pat}"
      {"Agent", %{"prompt" => p}} -> "Spawned agent: #{String.slice(p, 0..60)}"
      {"list_agents", _} -> "Listed all agents"
      {"spawn_agent", %{"name" => n}} -> "Spawned agent #{n}"
      {"send_message_to_agent", %{"agent_id" => id}} -> "Sent message to agent #{String.slice(id, 0..8)}"
      {"stop_agent", %{"agent_id" => id}} -> "Stopped agent #{String.slice(id, 0..8)}"
      {"exec", %{"command" => cmd}} -> "container $ #{String.slice(cmd, 0..80)}"
      {"logs", _} -> "Checked container logs"
      {"inspect_env", _} -> "Inspected container environment"
      {"start_service", %{"name" => n, "command" => cmd}} -> "Started service #{n}: #{String.slice(cmd, 0..60)}"
      {"start_service", %{"name" => n}} -> "Started service #{n}"
      {"ports", _} -> "Listed container ports"
      {name, _} -> name |> String.replace("_", " ") |> String.capitalize()
    end
  end

  defp tool_summary(tool_name, _input), do: tool_name

  # Pretty-print JSON tool results, pass through everything else
  defp format_tool_result(content) do
    case Jason.decode(content) do
      {:ok, parsed} when is_map(parsed) ->
        Jason.encode!(parsed, pretty: true)
      _ ->
        content
    end
  end

  # =============================================
  # Components
  # =============================================

  @impl true
  def render(assigns) do
    ~H"""
    <div id="chat-page" phx-hook="ScrollBottom" class="h-screen flex flex-col bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100">
      <.header agent_count={length(@agents)} />
      <div class="flex-1 flex min-h-0">
        <.sidebar agents={@agents} selected_id={@selected_id} />
        <main class="flex-1 flex flex-col min-w-0">
          <.new_agent_screen :if={@live_action == :new} />
          <.booting_screen :if={@live_action != :new && @booting_agent_id && !@selected_agent} agent_id={@booting_agent_id} status={@boot_status} />
          <.empty_state :if={@live_action != :new && !@booting_agent_id && !@selected_agent} />
          <.agent_view :if={@live_action != :new && @selected_agent} {assigns} />
        </main>
      </div>
    </div>
    """
  end

  defp header(assigns) do
    ~H"""
    <header class="flex-none h-14 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center justify-between px-4 md:px-5">
      <div class="flex items-center gap-3">
        <h1 class="text-lg font-semibold tracking-tight">Boom Looper</h1>
        <span class="text-sm text-zinc-400 dark:text-zinc-500">{@agent_count} agent{if @agent_count != 1, do: "s"}</span>
      </div>
    </header>
    """
  end

  defp sidebar(assigns) do
    ~H"""
    <aside class="w-72 md:w-80 flex-none border-r border-zinc-200 dark:border-zinc-700/80 flex flex-col bg-zinc-50 dark:bg-zinc-900/50">
      <div class="flex-none p-3 border-b border-zinc-200 dark:border-zinc-700/80">
        <.link
          navigate="/new"
          class="w-full inline-flex items-center justify-center gap-1.5 rounded-lg bg-zinc-900 dark:bg-zinc-100 px-3.5 py-2 text-sm font-medium text-white dark:text-zinc-900
                 hover:bg-zinc-700 dark:hover:bg-zinc-300 transition-colors"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
            <path d="M8.75 3.75a.75.75 0 0 0-1.5 0v3.5h-3.5a.75.75 0 0 0 0 1.5h3.5v3.5a.75.75 0 0 0 1.5 0v-3.5h3.5a.75.75 0 0 0 0-1.5h-3.5v-3.5Z" />
          </svg>
          New Agent
        </.link>
      </div>
      <div class="flex-1 overflow-y-auto">
        <div :if={@agents == []} class="flex flex-col items-center justify-center h-full px-6 text-center">
          <p class="text-sm text-zinc-400 dark:text-zinc-500">No agents yet</p>
        </div>
        <.agent_list_item :for={agent <- @agents} agent={agent} selected={@selected_id == agent.id} />
      </div>
    </aside>
    """
  end

  # --- New Agent Screen ---

  defp new_agent_screen(assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center p-8">
      <div class="w-full max-w-lg">
        <h2 class="text-xl font-semibold text-zinc-900 dark:text-zinc-100 mb-1">New Agent</h2>
        <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-6">Runs in a container with the working directory mounted.</p>
        <form phx-submit="spawn_agent" class="space-y-4">
          <div>
            <label class="block text-xs font-medium text-zinc-500 dark:text-zinc-400 mb-1.5 uppercase tracking-wider">Name</label>
            <input type="text" name="name" placeholder="Auto-generated if blank" autocomplete="off" autofocus
              class="w-full rounded-xl border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-4 py-3 text-sm
                     text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400
                     focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400" />
          </div>
          <div>
            <label class="block text-xs font-medium text-zinc-500 dark:text-zinc-400 mb-1.5 uppercase tracking-wider">Working Directory</label>
            <input type="text" name="working_dir" value={File.cwd!()}
              class="w-full rounded-xl border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-4 py-3 text-sm font-mono
                     text-zinc-600 dark:text-zinc-300
                     focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400" />
          </div>
          <div class="flex gap-3 pt-2">
            <button type="submit"
              class="flex-1 rounded-xl bg-zinc-900 dark:bg-zinc-100 px-4 py-3 text-sm font-medium text-white dark:text-zinc-900
                     hover:bg-zinc-700 dark:hover:bg-zinc-300 transition-colors">
              Launch
            </button>
            <.link navigate="/"
              class="rounded-xl px-4 py-3 text-sm font-medium text-zinc-500 hover:bg-zinc-100 dark:hover:bg-zinc-700 transition-colors">
              Cancel
            </.link>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # --- Sidebar ---

  defp agent_list_item(assigns) do
    ~H"""
    <button
      phx-click="select_agent"
      phx-value-id={@agent.id}
      class={"w-full text-left px-4 py-3 border-b border-zinc-200/80 dark:border-zinc-700/50 transition-colors
             #{if @selected, do: "bg-white dark:bg-zinc-800 shadow-sm", else: "hover:bg-white/60 dark:hover:bg-zinc-800/40"}"}
    >
      <div class="flex items-center gap-2.5">
        <div class={"w-2 h-2 rounded-full flex-none #{status_dot(@agent.status)}"}></div>
        <span class="text-sm font-medium truncate">{@agent.name}</span>
        <span :if={@agent.status == :booting} class="text-xs text-violet-400 flex-none">booting</span>
        <span :if={@agent.status == :thinking} class="text-xs text-amber-500 flex-none">thinking</span>
        <span :if={@agent.status == :destroying} class="text-xs text-red-400 flex-none">destroying</span>
        <span :if={@agent.status in [:stopped, :crashed]}
          phx-click="remove_agent" phx-value-id={@agent.id}
          class="ml-auto text-xs text-zinc-400 hover:text-red-500 dark:hover:text-red-400 flex-none transition-colors"
          title="Remove agent">
          &times;
        </span>
      </div>
      <div :if={@agent.status == :booting} class="mt-1 ml-[18px] text-xs text-zinc-400 dark:text-zinc-500 truncate">{@agent[:boot_status] || "Initializing..."}</div>
      <div :if={@agent.status != :booting} class="mt-1 ml-[18px] text-xs text-zinc-400 dark:text-zinc-500 font-mono truncate">{shorten_path(@agent.working_dir)}</div>
    </button>
    """
  end

  defp booting_screen(assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center">
      <div class="text-center max-w-sm">
        <div class="w-16 h-16 rounded-2xl bg-violet-100 dark:bg-violet-900/30 flex items-center justify-center mx-auto mb-4">
          <svg class="w-7 h-7 text-violet-500 animate-spin" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
            <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
          </svg>
        </div>
        <h3 class="text-sm font-semibold text-zinc-900 dark:text-zinc-100 mb-1">Starting agent</h3>
        <p class="text-xs text-zinc-400 dark:text-zinc-500 font-mono mb-3">{@agent_id}</p>
        <p class="text-sm text-zinc-500 dark:text-zinc-400">{@status}</p>
      </div>
    </div>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center">
      <div class="text-center">
        <div class="w-16 h-16 rounded-2xl bg-zinc-100 dark:bg-zinc-800 flex items-center justify-center mx-auto mb-4">
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="w-7 h-7 text-zinc-300 dark:text-zinc-600">
            <path fill-rule="evenodd" d="M4.848 2.771A49.144 49.144 0 0 1 12 2.25c2.43 0 4.817.178 7.152.52 1.978.29 3.348 2.024 3.348 3.97v6.02c0 1.946-1.37 3.68-3.348 3.97a48.901 48.901 0 0 1-3.476.383.39.39 0 0 0-.297.17l-2.755 4.133a.75.75 0 0 1-1.248 0l-2.755-4.133a.39.39 0 0 0-.297-.17 48.9 48.9 0 0 1-3.476-.384c-1.978-.29-3.348-2.024-3.348-3.97V6.741c0-1.946 1.37-3.68 3.348-3.97Z" clip-rule="evenodd" />
          </svg>
        </div>
        <p class="text-sm text-zinc-400 dark:text-zinc-500">Create or select an agent to start chatting</p>
      </div>
    </div>
    """
  end

  # --- Agent View ---

  defp agent_view(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col min-h-0">
      <.agent_header agent={@selected_agent} tab={@tab} has_container={@has_container} />
      <.chat_panel :if={@tab == :chat} messages={@messages} streaming_text={@streaming_text} agent={@selected_agent} />
      <.container_panel :if={@tab == :container} env={@container_env} logs={@container_logs} log_service={@container_log_service} has_container={@has_container} />
    </div>
    """
  end

  defp agent_header(assigns) do
    port = if assigns.has_container, do: Hive.Docker.host_port(assigns.agent.id), else: nil
    assigns = assign(assigns, :container_port, port)

    ~H"""
    <div class="flex-none border-b border-zinc-200 dark:border-zinc-700/80">
      <div class="flex items-center justify-between px-4 md:px-5 h-12">
        <div class="flex items-center gap-3">
          <div class={"w-2 h-2 rounded-full #{status_dot(@agent.status)}"}></div>
          <form phx-submit="rename_agent" class="inline">
            <input type="text" name="name" value={@agent.name}
              class="text-sm font-semibold bg-transparent border-none p-0 focus:outline-none focus:ring-0
                     text-zinc-900 dark:text-zinc-100 w-auto
                     hover:text-violet-600 dark:hover:text-violet-400 cursor-text"
              style={"width: #{max(String.length(@agent.name) * 8, 60)}px"} />
          </form>
          <a :if={@container_port} href={"http://localhost:#{@container_port}"} target="_blank"
            class="text-xs font-mono text-violet-500 hover:text-violet-400 transition-colors">
            localhost:{@container_port}
          </a>
          <span :if={@agent[:last_activity_at]} class="text-xs text-zinc-400 dark:text-zinc-500">
            {time_ago(@agent[:last_activity_at])}
          </span>
        </div>
        <button :if={@agent.status in [:idle, :thinking]} phx-click="stop_agent" phx-value-id={@agent.id}
          class="text-xs font-medium text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-500/10 rounded-md px-2 py-1">
          Stop
        </button>
        <button :if={@agent.status in [:stopped, :crashed]} phx-click="remove_agent" phx-value-id={@agent.id}
          class="text-xs font-medium text-zinc-500 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-700 rounded-md px-2 py-1">
          Remove
        </button>
        <span :if={@agent.status == :destroying}
          class="text-xs font-medium text-red-400 px-2 py-1">
          Destroying...
        </span>
      </div>
      <div :if={@has_container} class="flex gap-0 px-4">
        <button phx-click="switch_tab" phx-value-tab="chat"
          class={"px-3 py-1.5 text-xs font-medium border-b-2 transition-colors #{if @tab == :chat, do: "border-violet-500 text-violet-600 dark:text-violet-400", else: "border-transparent text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"}"}>
          Chat
        </button>
        <button phx-click="switch_tab" phx-value-tab="container"
          class={"px-3 py-1.5 text-xs font-medium border-b-2 transition-colors #{if @tab == :container, do: "border-violet-500 text-violet-600 dark:text-violet-400", else: "border-transparent text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"}"}>
          Container
        </button>
      </div>
    </div>
    """
  end

  # --- Chat Panel (unified activity feed) ---

  defp chat_panel(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col min-h-0">
      <div id="messages" class="flex-1 overflow-y-auto px-4 md:px-6 py-4 space-y-1">
        <div :for={msg <- @messages}>
          <.chat_msg msg={msg} />
        </div>
        <.streaming_bubble :if={@streaming_text != ""} text={@streaming_text} />
        <.thinking_indicator :if={@agent.status == :thinking && @streaming_text == "" && @messages != [] && List.last(@messages).role != :assistant} />
      </div>
      <div class="flex-none border-t border-zinc-200 dark:border-zinc-700/80 p-3 md:p-4 safe-area-bottom">
        <form id="chat-form" phx-submit="send_message" phx-hook="ChatForm" class="flex gap-2">
          <input
            type="text" name="message" id="chat-input"
            placeholder={if @agent.status == :thinking, do: "Claude is thinking...", else: "Type a message..."}
            autocomplete="off"
            class="flex-1 rounded-xl border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-4 py-2.5 text-sm
                   text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400
                   focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400" />
          <button type="submit"
            class="rounded-xl bg-violet-600 hover:bg-violet-700 px-4 py-2.5 text-sm font-medium text-white transition-colors flex-none">
            Send
          </button>
        </form>
      </div>
    </div>
    """
  end

  # User message — full chat bubble, right-aligned
  defp chat_msg(%{msg: %{role: :user}} = assigns) do
    ~H"""
    <div class="flex justify-end mt-3 mb-1">
      <div class="max-w-[85%] rounded-2xl rounded-tr-sm bg-violet-600 text-white px-4 py-2.5">
        <p class="text-sm whitespace-pre-wrap">{@msg.content}</p>
      </div>
    </div>
    """
  end

  # Assistant message — full chat bubble with avatar
  defp chat_msg(%{msg: %{role: :assistant}} = assigns) do
    ~H"""
    <div class="flex gap-3 mt-3 mb-1">
      <div class="flex-none w-7 h-7 rounded-full bg-violet-100 dark:bg-violet-900/40 flex items-center justify-center mt-0.5">
        <span class="text-xs font-bold text-violet-600 dark:text-violet-400">C</span>
      </div>
      <div class="max-w-[85%] rounded-2xl rounded-tl-sm bg-zinc-100 dark:bg-zinc-800 px-4 py-2.5">
        <p class="text-sm whitespace-pre-wrap text-zinc-900 dark:text-zinc-100">{@msg.content}</p>
      </div>
    </div>
    """
  end

  # Tool call — compact inline status row (like a Slack bot message)
  defp chat_msg(%{msg: %{role: :tool}} = assigns) do
    assigns = assign(assigns, :summary, tool_summary(assigns.msg.tool, assigns.msg.input))

    ~H"""
    <div class="flex items-center gap-2 py-0.5 pl-10">
      <div class="w-4 h-4 rounded bg-blue-100 dark:bg-blue-900/30 flex items-center justify-center flex-none">
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-2.5 h-2.5 text-blue-500 dark:text-blue-400">
          <path fill-rule="evenodd" d="M6.955 1.45A.5.5 0 0 1 7.452 1h1.096a.5.5 0 0 1 .497.45l.17 1.699c.484.12.94.312 1.356.562l1.321-.916a.5.5 0 0 1 .67.033l.774.775a.5.5 0 0 1 .034.67l-.916 1.32c.25.417.443.873.563 1.357l1.699.17a.5.5 0 0 1 .45.497v1.096a.5.5 0 0 1-.45.497l-1.699.17c-.12.484-.312.94-.562 1.356l.916 1.321a.5.5 0 0 1-.034.67l-.774.774a.5.5 0 0 1-.67.033l-1.32-.916c-.417.25-.874.443-1.357.563l-.17 1.699a.5.5 0 0 1-.497.45H7.452a.5.5 0 0 1-.497-.45l-.17-1.699a4.973 4.973 0 0 1-1.356-.562l-1.321.916a.5.5 0 0 1-.67-.033l-.774-.775a.5.5 0 0 1-.034-.67l.916-1.32a4.971 4.971 0 0 1-.562-1.357l-1.699-.17A.5.5 0 0 1 1 8.548V7.452a.5.5 0 0 1 .45-.497l1.699-.17c.12-.484.312-.94.562-1.356l-.916-1.321a.5.5 0 0 1 .034-.67l.774-.774a.5.5 0 0 1 .67-.033l1.32.916c.417-.25.874-.443 1.357-.563l.17-1.699ZM8 10.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5Z" clip-rule="evenodd" />
        </svg>
      </div>
      <span class="text-xs text-zinc-500 dark:text-zinc-400">{@summary}</span>
      <span class="text-[10px] text-zinc-300 dark:text-zinc-600">{Calendar.strftime(@msg.timestamp, "%H:%M:%S")}</span>
    </div>
    """
  end

  # Tool result — inline output block (always visible, no collapse state to sync across clients)
  defp chat_msg(%{msg: %{role: :tool_result}} = assigns) do
    content = assigns.msg.content
    display = format_tool_result(content)
    lines = String.split(display, "\n")
    truncated = length(lines) > 40
    display = if truncated, do: Enum.take(lines, 40) |> Enum.join("\n"), else: display
    assigns = assign(assigns, display: display, truncated: truncated, is_error: assigns.msg.is_error, line_count: length(lines))

    ~H"""
    <div class="pl-10 py-0.5">
      <pre class={"p-3 rounded-lg text-xs font-mono overflow-x-auto max-h-80 overflow-y-auto whitespace-pre-wrap
                   #{if @is_error, do: "bg-red-50 dark:bg-red-950/30 text-red-700 dark:text-red-300", else: "bg-zinc-950 text-green-400"}"}>{@display}</pre>
      <p :if={@truncated} class="mt-1 text-[10px] text-zinc-400 dark:text-zinc-500">... truncated ({@line_count - 40} more lines)</p>
    </div>
    """
  end

  # Error — compact inline alert (like a Slack system message)
  defp chat_msg(%{msg: %{role: :error}} = assigns) do
    ~H"""
    <div class="flex items-start gap-2 py-1 pl-10">
      <div class="w-4 h-4 rounded bg-red-100 dark:bg-red-900/30 flex items-center justify-center flex-none mt-0.5">
        <span class="text-[10px] font-bold text-red-500">!</span>
      </div>
      <span class="text-xs text-red-600 dark:text-red-400">{@msg.content}</span>
      <span class="text-[10px] text-zinc-300 dark:text-zinc-600 flex-none">{Calendar.strftime(@msg.timestamp, "%H:%M:%S")}</span>
    </div>
    """
  end

  defp chat_msg(assigns) do
    ~H"""
    <div></div>
    """
  end

  defp streaming_bubble(assigns) do
    ~H"""
    <div class="flex gap-3 mt-3">
      <div class="flex-none w-7 h-7 rounded-full bg-violet-100 dark:bg-violet-900/40 flex items-center justify-center mt-0.5">
        <span class="text-xs font-bold text-violet-600 dark:text-violet-400">C</span>
      </div>
      <div class="max-w-[85%] rounded-2xl rounded-tl-sm bg-zinc-100 dark:bg-zinc-800 px-4 py-2.5">
        <p class="text-sm whitespace-pre-wrap text-zinc-900 dark:text-zinc-100">{@text}<span class="inline-block w-1.5 h-4 bg-violet-500 animate-pulse ml-0.5 align-middle"></span></p>
      </div>
    </div>
    """
  end

  defp thinking_indicator(assigns) do
    ~H"""
    <div class="flex gap-3 mt-3">
      <div class="flex-none w-7 h-7 rounded-full bg-violet-100 dark:bg-violet-900/40 flex items-center justify-center mt-0.5">
        <span class="text-xs font-bold text-violet-600 dark:text-violet-400">C</span>
      </div>
      <div class="rounded-2xl rounded-tl-sm bg-zinc-100 dark:bg-zinc-800 px-4 py-3">
        <div class="flex gap-1">
          <div class="w-2 h-2 rounded-full bg-zinc-400 animate-bounce" style="animation-delay: 0ms"></div>
          <div class="w-2 h-2 rounded-full bg-zinc-400 animate-bounce" style="animation-delay: 150ms"></div>
          <div class="w-2 h-2 rounded-full bg-zinc-400 animate-bounce" style="animation-delay: 300ms"></div>
        </div>
      </div>
    </div>
    """
  end

  # --- Container Panel ---

  defp container_panel(%{has_container: false} = assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center">
      <p class="text-sm text-zinc-400 dark:text-zinc-500">No container running</p>
    </div>
    """
  end

  defp container_panel(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col min-h-0 overflow-y-auto">
      <div class="flex items-center justify-end px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50 border-b border-zinc-200 dark:border-zinc-700/80">
        <button phx-click="refresh_container" class="text-xs text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors">
          Refresh
        </button>
      </div>
      <div :if={@env} class="border-b border-zinc-200 dark:border-zinc-700/80">
        <div class="px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50">
          <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">Environment</h3>
        </div>
        <pre class="px-4 py-3 text-xs font-mono text-zinc-600 dark:text-zinc-400 overflow-x-auto whitespace-pre-wrap max-h-48 overflow-y-auto">{@env}</pre>
      </div>
      <div class="flex-1 flex flex-col min-h-0">
        <div class="flex items-center justify-between px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50 border-b border-zinc-200 dark:border-zinc-700/80">
          <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">Logs</h3>
          <form phx-change="filter_container_service" class="inline">
            <input type="text" name="service" value={@log_service || ""} placeholder="Filter service..."
              class="text-xs rounded border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-2 py-1 w-28
                     focus:outline-none focus:ring-1 focus:ring-violet-500/30" />
          </form>
        </div>
        <pre class="flex-1 px-4 py-3 text-xs font-mono overflow-auto whitespace-pre-wrap bg-zinc-950 text-green-400 min-h-[200px]">{@logs}</pre>
      </div>
    </div>
    """
  end
end
