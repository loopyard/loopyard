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
     |> assign(:new_working_dir, File.cwd!())}
  end

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket) do
    if prev = socket.assigns.selected_id do
      ChatAgent.unsubscribe(prev)
    end

    ChatAgent.subscribe(id)
    agent = ChatAgent.get_state(id)

    {:noreply,
     socket
     |> assign(:selected_id, id)
     |> assign(:selected_agent, agent)
     |> assign(:messages, agent.messages)
     |> assign(:streaming_text, "")}
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
      |> then(fn n -> if n == "", do: "Chat #{String.slice(id, 0..5)}", else: n end)

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
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Helpers ---

  defp status_label(:idle), do: "Idle"
  defp status_label(:thinking), do: "Thinking..."
  defp status_label(:stopped), do: "Stopped"
  defp status_label(_), do: ""

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

  defp truncate(str, max) when is_binary(str) and byte_size(str) > max do
    String.slice(str, 0, max) <> "\n... (truncated)"
  end

  defp truncate(str, _max) when is_binary(str), do: str
  defp truncate(other, _max), do: inspect(other)

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
        <a href="/terminal" class="text-sm text-zinc-400 dark:text-zinc-500 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors">
          Terminal mode &rarr;
        </a>
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

          <%!-- Chat view --%>
          <div :if={@selected_agent} class="flex-1 flex flex-col min-h-0">
            <%!-- Agent header --%>
            <div class="flex-none flex items-center justify-between px-4 md:px-5 h-12 border-b border-zinc-200 dark:border-zinc-700/80">
              <div class="flex items-center gap-3">
                <div class={"w-2 h-2 rounded-full #{status_dot(@selected_agent.status)}"}></div>
                <span class="text-sm font-semibold">{@selected_agent.name}</span>
                <span class="text-xs text-zinc-400 dark:text-zinc-500">{status_label(@selected_agent.status)}</span>
              </div>
              <button phx-click="stop_agent" phx-value-id={@selected_agent.id}
                class="text-xs font-medium text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-500/10 rounded-md px-2 py-1">
                Stop
              </button>
            </div>

            <%!-- Messages --%>
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
              <form phx-submit="send_message" class="flex gap-2">
                <input
                  type="text"
                  name="message"
                  value={@input}
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
    <%!-- Tool result --%>
    <div :if={@msg.role == :tool_result} class="flex gap-3">
      <div class="flex-none w-7 h-7 rounded-full bg-green-100 dark:bg-green-900/40 flex items-center justify-center mt-0.5">
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5 text-green-600 dark:text-green-400">
          <path fill-rule="evenodd" d="M12.416 3.376a.75.75 0 0 1 .208 1.04l-5 7.5a.75.75 0 0 1-1.154.114l-3-3a.75.75 0 0 1 1.06-1.06l2.353 2.353 4.493-6.74a.75.75 0 0 1 1.04-.207Z" clip-rule="evenodd" />
        </svg>
      </div>
      <div class="max-w-[85%] rounded-xl bg-green-50 dark:bg-green-900/20 border border-green-200/60 dark:border-green-800/60 px-4 py-2.5">
        <pre class="text-xs text-green-700 dark:text-green-300 overflow-x-auto whitespace-pre-wrap max-h-48 overflow-y-auto">{truncate(@msg.output, 500)}</pre>
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
