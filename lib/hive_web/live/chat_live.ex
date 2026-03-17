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
     |> assign(:input, "")
     |> assign(:show_new_form, false)
     |> assign(:new_name, "")
     |> assign(:new_working_dir, File.cwd!())
     |> assign(:tab, :chat)
     |> assign(:ops_logs, "")
     |> assign(:ops_env, nil)
     |> assign(:ops_log_service, nil)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: action}} = socket) do
    tab = if action == :ops, do: :ops, else: :chat

    socket =
      if socket.assigns.selected_id != id do
        {:noreply, s} = select_agent(socket, id)
        s
      else
        socket
      end

    socket = assign(socket, :tab, tab)
    socket = if tab == :ops, do: fetch_ops_data(socket), else: socket
    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, :tab, :chat)}

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket) do
    tab = socket.assigns.tab
    path = if tab == :ops, do: "/chat/#{id}/ops", else: "/chat/#{id}"
    {:noreply, push_patch(socket, to: path) |> push_event("focus_input", %{})}
  end

  @impl true
  def handle_event("toggle_new_form", _params, socket) do
    {:noreply, assign(socket, :show_new_form, !socket.assigns.show_new_form)}
  end

  @impl true
  def handle_event("spawn_agent", params, socket) do
    working_dir = Map.get(params, "working_dir", File.cwd!())
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    name =
      Map.get(params, "name", "")
      |> then(fn n -> if n == "", do: auto_name(), else: n end)

    case Hive.ChatAgentSupervisor.start_agent(
           id: id,
           name: name,
           working_dir: working_dir,
           started_by: "browser"
         ) do
      {:ok, _pid} ->
        send(self(), {:auto_select, id})
        {:noreply, socket |> assign(:show_new_form, false) |> assign(:new_name, "")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("send_message", %{"message" => message}, socket) do
    message = String.trim(message)

    if message != "" && socket.assigns.selected_id do
      ChatAgent.send_message(socket.assigns.selected_id, message)
    end

    {:noreply, assign(socket, :input, "")}
  end

  @impl true
  def handle_event("stop_agent", %{"id" => id}, socket) do
    ChatAgent.stop_agent(id)
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
        {id, :ops} -> "/chat/#{id}/ops"
        {id, _} -> "/chat/#{id}"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("refresh_ops", _params, socket) do
    {:noreply, fetch_ops_data(socket)}
  end

  @impl true
  def handle_event("filter_ops_service", %{"service" => service}, socket) do
    service = if service == "", do: nil, else: service
    socket = assign(socket, :ops_log_service, service)
    {:noreply, fetch_ops_data(socket)}
  end

  # PubSub: global
  @impl true
  def handle_info({:chat_agent_started, _}, socket) do
    {:noreply, assign(socket, :agents, ChatAgent.list_agents())}
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
        socket = assign(socket, :selected_agent, selected)

        if status == :idle && socket.assigns.streaming_text != "" do
          msg = %{role: :assistant, content: socket.assigns.streaming_text, timestamp: DateTime.utc_now()}

          socket
          |> assign(:messages, socket.assigns.messages ++ [msg])
          |> assign(:streaming_text, "")
        else
          socket
        end
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:chat_message, id, msg}, socket) when id == socket.assigns.selected_id do
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
  def handle_info({:auto_select, id}, socket) do
    {:noreply, push_patch(socket, to: "/chat/#{id}")}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp select_agent(socket, id) do
    # Unsubscribe from previous
    if prev = socket.assigns.selected_id do
      ChatAgent.unsubscribe(prev)
    end

    try do
      ChatAgent.subscribe(id)
      agent = ChatAgent.get_state(id)
      agents = ChatAgent.list_agents()

      {:noreply,
       socket
       |> assign(:agents, agents)
       |> assign(:selected_id, id)
       |> assign(:selected_agent, agent)
       |> assign(:messages, agent.messages)
       |> assign(:streaming_text, "")}
    catch
      :exit, _ ->
        # Agent doesn't exist (maybe expired) — redirect to index
        {:noreply, push_patch(socket, to: "/")}
    end
  end

  defp fetch_ops_data(socket) do
    case socket.assigns.selected_id do
      nil ->
        socket

      id ->
        log_opts = %{lines: 100}
        log_opts = if socket.assigns.ops_log_service, do: Map.put(log_opts, :service, socket.assigns.ops_log_service), else: log_opts

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
        |> assign(:ops_logs, logs)
        |> assign(:ops_env, env)
    end
  end

  @adjectives ~w(Swift Bright Calm Deep Quick Sharp Keen Bold Clear True)
  @nouns ~w(Spark Drift Pulse Wave Bloom Forge Sage Fern Tide Mesa)

  defp auto_name do
    adj = Enum.random(@adjectives)
    noun = Enum.random(@nouns)
    "#{adj} #{noun}"
  end

  defp status_dot(:idle), do: "bg-green-500"
  defp status_dot(:thinking), do: "bg-amber-400 animate-pulse"
  defp status_dot(:stopped), do: "bg-zinc-400"
  defp status_dot(_), do: "bg-zinc-400"

  defp shorten_path(path) do
    home = System.user_home!()
    String.replace_prefix(path, home, "~")
  end

  defp format_tool_input(input) when is_map(input), do: Jason.encode!(input, pretty: true)
  defp format_tool_input(input), do: inspect(input)

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


  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div id="chat-page" phx-hook="ScrollBottom" class="h-screen flex flex-col bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100">
      <%!-- Header --%>
      <header class="flex-none h-14 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center justify-between px-4 md:px-5">
        <div class="flex items-center gap-3">
          <h1 class="text-lg font-semibold tracking-tight">Hive</h1>
          <span class="text-sm text-zinc-400 dark:text-zinc-500">{length(@agents)} agent{if length(@agents) != 1, do: "s"}</span>
        </div>
      </header>

      <div class="flex-1 flex min-h-0">
        <%!-- Sidebar --%>
        <aside class="w-72 md:w-80 flex-none border-r border-zinc-200 dark:border-zinc-700/80 flex flex-col bg-zinc-50 dark:bg-zinc-900/50">
          <%!-- New agent button --%>
          <div class="flex-none p-3 border-b border-zinc-200 dark:border-zinc-700/80">
            <button
              :if={!@show_new_form}
              phx-click="toggle_new_form"
              class="w-full inline-flex items-center justify-center gap-1.5 rounded-lg bg-zinc-900 dark:bg-zinc-100 px-3.5 py-2 text-sm font-medium text-white dark:text-zinc-900
                     hover:bg-zinc-700 dark:hover:bg-zinc-300 transition-colors"
            >
              <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
                <path d="M8.75 3.75a.75.75 0 0 0-1.5 0v3.5h-3.5a.75.75 0 0 0 0 1.5h3.5v3.5a.75.75 0 0 0 1.5 0v-3.5h3.5a.75.75 0 0 0 0-1.5h-3.5v-3.5Z" />
              </svg>
              New Agent
            </button>

            <%!-- Inline new form --%>
            <form :if={@show_new_form} phx-submit="spawn_agent" class="space-y-2.5">
              <input type="text" name="name" value={@new_name} placeholder="Agent name" autocomplete="off" autofocus
                class="w-full rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-2 text-sm
                       text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400
                       focus:outline-none focus:ring-2 focus:ring-zinc-900/10 dark:focus:ring-zinc-400/20" />
              <input type="text" name="working_dir" value={@new_working_dir}
                class="w-full rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-2 text-sm font-mono
                       text-zinc-600 dark:text-zinc-300
                       focus:outline-none focus:ring-2 focus:ring-zinc-900/10 dark:focus:ring-zinc-400/20" />
              <div class="flex gap-2">
                <button type="submit" class="flex-1 rounded-lg bg-zinc-900 dark:bg-zinc-100 px-3 py-2 text-sm font-medium text-white dark:text-zinc-900
                       hover:bg-zinc-700 dark:hover:bg-zinc-300 transition-colors">
                  Launch
                </button>
                <button type="button" phx-click="toggle_new_form"
                  class="rounded-lg px-3 py-2 text-sm text-zinc-500 hover:bg-zinc-100 dark:hover:bg-zinc-700 transition-colors">
                  Cancel
                </button>
              </div>
            </form>
          </div>

          <%!-- Agent list --%>
          <div class="flex-1 overflow-y-auto">
            <div :if={@agents == []} class="flex flex-col items-center justify-center h-full px-6 text-center">
              <p class="text-sm text-zinc-400 dark:text-zinc-500">No agents yet</p>
            </div>
            <button
              :for={agent <- @agents}
              phx-click="select_agent"
              phx-value-id={agent.id}
              class={"w-full text-left px-4 py-3 border-b border-zinc-200/80 dark:border-zinc-700/50 transition-colors
                     #{if @selected_id == agent.id, do: "bg-white dark:bg-zinc-800 shadow-sm", else: "hover:bg-white/60 dark:hover:bg-zinc-800/40"}"}
            >
              <div class="flex items-center gap-2.5">
                <div class={"w-2 h-2 rounded-full flex-none #{status_dot(agent.status)}"}></div>
                <span class="text-sm font-medium truncate">{agent.name}</span>
                <span :if={agent.status == :thinking} class="text-xs text-amber-500 flex-none">thinking</span>
              </div>
              <div class="mt-1 ml-[18px] text-xs text-zinc-400 dark:text-zinc-500 font-mono truncate">{shorten_path(agent.working_dir)}</div>
            </button>
          </div>
        </aside>

        <%!-- Main panel --%>
        <main class="flex-1 flex flex-col min-w-0">
          <%!-- Empty state --%>
          <div :if={!@selected_agent} class="flex-1 flex items-center justify-center">
            <div class="text-center">
              <div class="w-16 h-16 rounded-2xl bg-zinc-100 dark:bg-zinc-800 flex items-center justify-center mx-auto mb-4">
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="w-7 h-7 text-zinc-300 dark:text-zinc-600">
                  <path fill-rule="evenodd" d="M4.848 2.771A49.144 49.144 0 0 1 12 2.25c2.43 0 4.817.178 7.152.52 1.978.29 3.348 2.024 3.348 3.97v6.02c0 1.946-1.37 3.68-3.348 3.97a48.901 48.901 0 0 1-3.476.383.39.39 0 0 0-.297.17l-2.755 4.133a.75.75 0 0 1-1.248 0l-2.755-4.133a.39.39 0 0 0-.297-.17 48.9 48.9 0 0 1-3.476-.384c-1.978-.29-3.348-2.024-3.348-3.97V6.741c0-1.946 1.37-3.68 3.348-3.97Z" clip-rule="evenodd" />
                </svg>
              </div>
              <p class="text-sm text-zinc-400 dark:text-zinc-500">Create or select an agent to start chatting</p>
            </div>
          </div>

          <%!-- Agent view --%>
          <div :if={@selected_agent} class="flex-1 flex flex-col min-h-0">
            <%!-- Agent header with tabs --%>
            <div class="flex-none border-b border-zinc-200 dark:border-zinc-700/80">
              <div class="flex items-center justify-between px-4 md:px-5 h-12">
                <div class="flex items-center gap-3">
                  <div class={"w-2 h-2 rounded-full #{status_dot(@selected_agent.status)}"}></div>
                  <form phx-submit="rename_agent" class="inline">
                    <input type="text" name="name" value={@selected_agent.name}
                      class="text-sm font-semibold bg-transparent border-none p-0 focus:outline-none focus:ring-0
                             text-zinc-900 dark:text-zinc-100 w-auto
                             hover:text-violet-600 dark:hover:text-violet-400 cursor-text"
                      style={"width: #{max(String.length(@selected_agent.name) * 8, 60)}px"} />
                  </form>
                  <span :if={@selected_agent[:last_activity_at]} class="text-xs text-zinc-400 dark:text-zinc-500">
                    {time_ago(@selected_agent[:last_activity_at])}
                  </span>
                </div>
                <button phx-click="stop_agent" phx-value-id={@selected_agent.id}
                  class="text-xs font-medium text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-500/10 rounded-md px-2 py-1">
                  Stop
                </button>
              </div>
              <%!-- Tabs --%>
              <div class="flex gap-0 px-4">
                <button phx-click="switch_tab" phx-value-tab="chat"
                  class={"px-3 py-1.5 text-xs font-medium border-b-2 transition-colors #{if @tab == :chat, do: "border-violet-500 text-violet-600 dark:text-violet-400", else: "border-transparent text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"}"}>
                  Chat
                </button>
                <button phx-click="switch_tab" phx-value-tab="ops"
                  class={"px-3 py-1.5 text-xs font-medium border-b-2 transition-colors #{if @tab == :ops, do: "border-violet-500 text-violet-600 dark:text-violet-400", else: "border-transparent text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"}"}>
                  Ops
                  <span :if={@selected_agent[:errors] && @selected_agent.errors > 0}
                    class="ml-1 inline-flex items-center justify-center w-4 h-4 text-[10px] font-bold text-white bg-red-500 rounded-full">
                    {@selected_agent.errors}
                  </span>
                </button>
              </div>
            </div>

            <%!-- Chat tab --%>
            <div :if={@tab == :chat} class="flex-1 flex flex-col min-h-0">
            <div id="messages" class="flex-1 overflow-y-auto px-4 md:px-6 py-4 space-y-3">
              <div :for={msg <- @messages}>
                <.msg_bubble msg={msg} />
              </div>
              <%!-- Streaming --%>
              <div :if={@streaming_text != ""} class="flex gap-3">
                <div class="flex-none w-7 h-7 rounded-full bg-violet-100 dark:bg-violet-900/40 flex items-center justify-center mt-0.5">
                  <span class="text-xs font-bold text-violet-600 dark:text-violet-400">C</span>
                </div>
                <div class="max-w-[85%] rounded-2xl rounded-tl-sm bg-zinc-100 dark:bg-zinc-800 px-4 py-2.5">
                  <p class="text-sm whitespace-pre-wrap text-zinc-900 dark:text-zinc-100">{@streaming_text}<span class="inline-block w-1.5 h-4 bg-violet-500 animate-pulse ml-0.5 align-middle"></span></p>
                </div>
              </div>
              <%!-- Thinking indicator --%>
              <div :if={@selected_agent.status == :thinking && @streaming_text == "" && @messages != [] && List.last(@messages).role != :assistant} class="flex gap-3">
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
            </div>

            <%!-- Input --%>
            <div class="flex-none border-t border-zinc-200 dark:border-zinc-700/80 p-3 md:p-4 safe-area-bottom">
              <form id="chat-form" phx-submit="send_message" phx-hook="ChatForm" class="flex gap-2">
                <input
                  type="text"
                  name="message"
                  id="chat-input"
                  placeholder={if @selected_agent.status == :thinking, do: "Claude is thinking...", else: "Type a message..."}
                  autocomplete="off"
                  class="flex-1 rounded-xl border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-4 py-2.5 text-sm
                         text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400
                         focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400"
                />
                <button type="submit"
                  class="rounded-xl bg-violet-600 hover:bg-violet-700 px-4 py-2.5 text-sm font-medium text-white transition-colors flex-none">
                  Send
                </button>
              </form>
            </div>
            </div>

            <%!-- Ops tab --%>
            <div :if={@tab == :ops} class="flex-1 flex flex-col min-h-0 overflow-y-auto">
              <%!-- Quick stats --%>
              <div class="flex gap-4 px-4 py-3 border-b border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50">
                <div class="text-center">
                  <div class="text-lg font-semibold text-zinc-900 dark:text-zinc-100">{@selected_agent[:tool_calls] || 0}</div>
                  <div class="text-[10px] uppercase tracking-wider text-zinc-400">Tools</div>
                </div>
                <div class="text-center">
                  <div class={"text-lg font-semibold #{if (@selected_agent[:errors] || 0) > 0, do: "text-red-500", else: "text-zinc-900 dark:text-zinc-100"}"}>{@selected_agent[:errors] || 0}</div>
                  <div class="text-[10px] uppercase tracking-wider text-zinc-400">Errors</div>
                </div>
                <div class="text-center">
                  <div class="text-lg font-semibold text-zinc-900 dark:text-zinc-100">{length(@messages)}</div>
                  <div class="text-[10px] uppercase tracking-wider text-zinc-400">Messages</div>
                </div>
                <div class="flex-1"></div>
                <button phx-click="refresh_ops"
                  class="self-center text-xs text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors">
                  Refresh
                </button>
              </div>

              <%!-- Environment --%>
              <div :if={@ops_env} class="border-b border-zinc-200 dark:border-zinc-700/80">
                <div class="px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50">
                  <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">Environment</h3>
                </div>
                <pre class="px-4 py-3 text-xs font-mono text-zinc-600 dark:text-zinc-400 overflow-x-auto whitespace-pre-wrap max-h-48 overflow-y-auto">{@ops_env}</pre>
              </div>

              <div :if={!@ops_env} class="px-4 py-3 border-b border-zinc-200 dark:border-zinc-700/80">
                <p class="text-xs text-zinc-400">No container running</p>
              </div>

              <%!-- Logs --%>
              <div class="flex-1 flex flex-col min-h-0">
                <div class="flex items-center justify-between px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50 border-b border-zinc-200 dark:border-zinc-700/80">
                  <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">Logs</h3>
                  <form phx-change="filter_ops_service" class="inline">
                    <input type="text" name="service" value={@ops_log_service || ""} placeholder="Filter service..."
                      class="text-xs rounded border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-2 py-1 w-28
                             focus:outline-none focus:ring-1 focus:ring-violet-500/30" />
                  </form>
                </div>
                <pre class="flex-1 px-4 py-3 text-xs font-mono overflow-auto whitespace-pre-wrap bg-zinc-950 text-green-400 min-h-[200px]">{@ops_logs}</pre>
              </div>
            </div>
          </div>
        </main>
      </div>
    </div>
    """
  end

  defp msg_bubble(assigns) do
    ~H"""
    <%!-- User --%>
    <div :if={@msg.role == :user} class="flex justify-end">
      <div class="max-w-[85%] rounded-2xl rounded-tr-sm bg-violet-600 text-white px-4 py-2.5">
        <p class="text-sm whitespace-pre-wrap">{@msg.content}</p>
      </div>
    </div>
    <%!-- Assistant --%>
    <div :if={@msg.role == :assistant} class="flex gap-3">
      <div class="flex-none w-7 h-7 rounded-full bg-violet-100 dark:bg-violet-900/40 flex items-center justify-center mt-0.5">
        <span class="text-xs font-bold text-violet-600 dark:text-violet-400">C</span>
      </div>
      <div class="max-w-[85%] rounded-2xl rounded-tl-sm bg-zinc-100 dark:bg-zinc-800 px-4 py-2.5">
        <p class="text-sm whitespace-pre-wrap text-zinc-900 dark:text-zinc-100">{@msg.content}</p>
      </div>
    </div>
    <%!-- Tool use --%>
    <div :if={@msg.role == :tool} class="flex gap-3">
      <div class="flex-none w-7 h-7 rounded-full bg-blue-100 dark:bg-blue-900/40 flex items-center justify-center mt-0.5">
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5 text-blue-600 dark:text-blue-400">
          <path fill-rule="evenodd" d="M11.986 3H12a2 2 0 0 1 2 2v6a2 2 0 0 1-1.5 1.937V7A2.5 2.5 0 0 0 10 4.5H4.063A2 2 0 0 1 6 3h.014A2.25 2.25 0 0 1 8.25 1h-.5a2.25 2.25 0 0 1 2.236 2ZM10.5 4v-.75a.75.75 0 0 0-.75-.75h-3.5a.75.75 0 0 0-.75.75V4h5Z" clip-rule="evenodd" />
          <path fill-rule="evenodd" d="M2 7a1 1 0 0 1 1-1h7a1 1 0 0 1 1 1v7a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V7Zm6.585 1.08a.75.75 0 0 1 .336 1.005l-1.75 3.5a.75.75 0 0 1-1.16.234l-1.75-1.5a.75.75 0 0 1 .977-1.139l1.02.875 1.321-2.64a.75.75 0 0 1 1.006-.335Z" clip-rule="evenodd" />
        </svg>
      </div>
      <div class="max-w-[85%] rounded-xl bg-blue-50 dark:bg-blue-900/20 border border-blue-200/60 dark:border-blue-800/60 px-4 py-2.5">
        <p class="text-xs font-semibold text-blue-700 dark:text-blue-300 mb-1">{@msg.tool}</p>
        <pre class="text-xs text-blue-600/80 dark:text-blue-400/80 overflow-x-auto whitespace-pre-wrap">{format_tool_input(@msg.input)}</pre>
      </div>
    </div>
    <%!-- Error --%>
    <div :if={@msg.role == :error} class="flex gap-3">
      <div class="flex-none w-7 h-7 rounded-full bg-red-100 dark:bg-red-900/40 flex items-center justify-center mt-0.5">
        <span class="text-xs font-bold text-red-600 dark:text-red-400">!</span>
      </div>
      <div class="max-w-[85%] rounded-xl bg-red-50 dark:bg-red-900/20 border border-red-200/60 dark:border-red-800/60 px-4 py-2.5">
        <p class="text-sm text-red-700 dark:text-red-300">{@msg.content}</p>
      </div>
    </div>
    """
  end
end
