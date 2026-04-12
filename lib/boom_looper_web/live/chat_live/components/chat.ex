defmodule BoomLooperWeb.Live.ChatLive.Components.Chat do
  @moduledoc "Chat panel components: agent_view, agent_header, chat_panel, thinking_indicator, context_panel, container_panel."
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  import BoomLooperWeb.Components.Sidebar, only: [status_dot: 1]
  import BoomLooperWeb.Live.ChatLive.Messages, only: [chat_msg: 1, streaming_bubble: 1]
  import BoomLooperWeb.Live.ChatLive.Components.Formatters, only: [time_ago: 1]

  def chat_header(assigns) do
    # Mobile back button has two modes:
    #   - viewing an agent/service -> patch back to the sidebar (Menu)
    #   - viewing the sidebar/new screen -> navigate up to the project page
    {back_kind, back_target, back_label} =
      cond do
        assigns.live_action in [:chat, :container, :service, :console, :services] ->
          {:patch, assigns.base_path, "Menu"}

        assigns.project ->
          {:navigate, "/projects/#{assigns.project.id}", assigns.project.name}

        true ->
          {:navigate, "/", "Projects"}
      end

    assigns =
      assigns
      |> assign(:back_kind, back_kind)
      |> assign(:back_target, back_target)
      |> assign(:back_label, back_label)

    ~H"""
    <header class="flex-none h-14 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center justify-between px-4 md:px-5">
      <div class="flex items-center gap-3 min-w-0">
        <.link
          :if={@back_kind == :patch}
          patch={@back_target}
          class="md:hidden -ml-1 inline-flex items-center gap-1 px-2 py-1 rounded-md text-sm font-medium text-violet-600 dark:text-violet-400 hover:bg-violet-50 dark:hover:bg-violet-500/10 active:bg-violet-100 dark:active:bg-violet-500/20 transition-colors flex-none min-w-0"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5 flex-none">
            <path fill-rule="evenodd" d="M17 10a.75.75 0 0 1-.75.75H5.612l4.158 3.96a.75.75 0 1 1-1.04 1.08l-5.5-5.25a.75.75 0 0 1 0-1.08l5.5-5.25a.75.75 0 1 1 1.04 1.08L5.612 9.25H16.25A.75.75 0 0 1 17 10Z" clip-rule="evenodd" />
          </svg>
          <span class="truncate">{@back_label}</span>
        </.link>
        <.link
          :if={@back_kind == :navigate}
          navigate={@back_target}
          class="md:hidden -ml-1 inline-flex items-center gap-1 px-2 py-1 rounded-md text-sm font-medium text-violet-600 dark:text-violet-400 hover:bg-violet-50 dark:hover:bg-violet-500/10 active:bg-violet-100 dark:active:bg-violet-500/20 transition-colors flex-none min-w-0"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5 flex-none">
            <path fill-rule="evenodd" d="M17 10a.75.75 0 0 1-.75.75H5.612l4.158 3.96a.75.75 0 1 1-1.04 1.08l-5.5-5.25a.75.75 0 0 1 0-1.08l5.5-5.25a.75.75 0 1 1 1.04 1.08L5.612 9.25H16.25A.75.75 0 0 1 17 10Z" clip-rule="evenodd" />
          </svg>
          <span class="truncate">{@back_label}</span>
        </.link>
        <.link navigate="/" class="text-sm font-semibold tracking-tight hover:text-violet-600 dark:hover:text-violet-400 transition-colors hidden md:block">Boom Looper</.link>
        <span class="text-zinc-300 dark:text-zinc-600 hidden md:block">/</span>
        <.link :if={@project} navigate={"/projects/#{@project.id}"} class="text-sm font-medium hover:text-violet-600 dark:hover:text-violet-400 transition-colors truncate">{@workspace.name}</.link>
        <span :if={!@project} class="text-sm font-medium truncate">{@workspace.name}</span>
        <span :if={@workspace_entry && !@workspace_entry[:is_main]} class="text-zinc-300 dark:text-zinc-600 hidden sm:block">/</span>
        <span :if={@workspace_entry && !@workspace_entry[:is_main]} class="text-sm text-zinc-500 dark:text-zinc-400 hidden sm:block truncate">{@workspace_entry.name}</span>
        <span class="text-sm text-zinc-400 dark:text-zinc-500 hidden sm:block flex-none">{@agent_count} agent{if @agent_count != 1, do: "s"}</span>
        <BoomLooperWeb.Components.AppHeader.iex_indicator :if={@iex_session.level} session={@iex_session} />
      </div>
      <div class="flex items-center gap-4 flex-none hidden md:flex">
        <.link navigate="/connect" class="text-xs text-zinc-400 dark:text-zinc-500 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors">Remote</.link>
        <.link navigate="/system" class="text-xs text-zinc-400 dark:text-zinc-500 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors">System</.link>
      </div>
    </header>
    """
  end

  # --- Agent View ---

  def agent_view(assigns) do
    ~H"""
    <div class="flex-1 flex min-h-0">
      <div class="flex-1 flex flex-col min-w-0 min-h-0">
        <.agent_header agent={@selected_agent} tab={@tab} has_container={@has_container} />
        <.chat_panel :if={@tab == :chat} messages={@messages} streaming_text={@streaming_text} agent={@selected_agent} workspace_id={@workspace.id} />
        <.container_panel :if={@tab == :container} env={@container_env} logs={@container_logs} log_service={@container_log_service} has_container={@has_container} />
      </div>
      <.context_panel agent={@selected_agent} has_container={@has_container} container_env={@container_env} container_logs={@container_logs} editing_name={@editing_name} />
    </div>
    """
  end

  def agent_header(assigns) do
    port = nil  # Ports are now shown per-process in the sidebar, not per-agent
    assigns = assign(assigns, :container_port, port)

    ~H"""
    <div class="flex-none border-b border-zinc-200 dark:border-zinc-700/80">
      <div class="flex items-center justify-between px-3 md:px-5 h-12 gap-2">
        <div class="flex items-center gap-2 md:gap-3 min-w-0">
          <div class={"w-2 h-2 rounded-full flex-none #{status_dot(@agent.status)}"}></div>
          <span class="text-sm font-semibold text-zinc-900 dark:text-zinc-100 truncate">{@agent.name}</span>
          <span :if={@agent[:last_activity_at]} class="text-xs text-zinc-400 dark:text-zinc-500 hidden sm:block flex-none">
            {time_ago(@agent[:last_activity_at])}
          </span>
        </div>
        <div class="flex items-center gap-1 md:gap-2 flex-none">
          <button :if={@agent.status in [:idle, :thinking]} phx-click="restart_session" phx-value-id={@agent.id}
            class="text-xs font-medium text-amber-600 dark:text-amber-400 hover:bg-amber-50 dark:hover:bg-amber-500/10 rounded-md px-2 py-1 hidden sm:block">
            Restart CLI
          </button>
          <button :if={@agent.status in [:idle, :thinking]} phx-click="stop_agent" phx-value-id={@agent.id}
            class="text-xs font-medium text-red-600 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-500/10 rounded-md px-2 py-1">
            Stop
          </button>
          <button :if={@agent.status in [:stopped, :crashed]} phx-click="start_agent" phx-value-id={@agent.id}
            class="text-xs font-medium text-green-600 dark:text-green-400 hover:bg-green-50 dark:hover:bg-green-500/10 rounded-md px-2 py-1">
            Start
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

  # --- Chat Panel ---

  def chat_panel(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col min-h-0">
      <div id="messages" class="flex-1 overflow-y-auto px-4 md:px-6 py-4 space-y-1">
        <div :for={{msg, idx} <- Enum.with_index(@messages)}>
          <.chat_msg msg={msg} idx={idx} agent_id={@agent.id} workspace_id={@workspace_id} />
        </div>
        <.streaming_bubble :if={@streaming_text != ""} text={@streaming_text} />
        <.thinking_indicator :if={@agent.status == :thinking && @streaming_text == ""} messages={@messages} />
      </div>
      <div id="chat-form-wrapper" phx-update="ignore" class="flex-none border-t border-zinc-200 dark:border-zinc-700/80 p-3 md:p-4 safe-area-bottom">
        <form id="chat-form" phx-submit="send_message" phx-hook="ChatForm" class="flex gap-2">
          <textarea
            name="message" id="chat-input" rows="1"
            placeholder="Type a message..."
            autocomplete="off"
            class="flex-1 rounded-xl border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-4 py-2.5 text-sm
                   text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 resize-none
                   focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400"></textarea>
          <button type="submit"
            class="rounded-xl bg-violet-600 hover:bg-violet-700 px-4 py-2.5 text-sm font-medium text-white transition-colors flex-none">
            Send
          </button>
        </form>
      </div>
    </div>
    """
  end

  def thinking_indicator(assigns) do
    # Find the last tool call to show what the agent is doing
    last_tool = assigns.messages
      |> Enum.reverse()
      |> Enum.find(&(&1.role == :tool))

    last_action = if last_tool do
      BoomLooperWeb.Components.ToolSummary.summarize(last_tool.tool, last_tool.input)
    else
      nil
    end

    assigns = assign(assigns, :last_action, last_action)

    ~H"""
    <div class="flex gap-3 mt-3">
      <div class="flex-none w-7 h-7 rounded-full bg-violet-100 dark:bg-violet-900/40 flex items-center justify-center mt-0.5">
        <span class="text-xs font-bold text-violet-600 dark:text-violet-400">C</span>
      </div>
      <div class="rounded-2xl rounded-tl-sm bg-zinc-100 dark:bg-zinc-800 px-4 py-3">
        <div class="flex items-center gap-3">
          <div class="flex gap-1">
            <div class="w-2 h-2 rounded-full bg-zinc-400 animate-bounce" style="animation-delay: 0ms"></div>
            <div class="w-2 h-2 rounded-full bg-zinc-400 animate-bounce" style="animation-delay: 150ms"></div>
            <div class="w-2 h-2 rounded-full bg-zinc-400 animate-bounce" style="animation-delay: 300ms"></div>
          </div>
          <span :if={@last_action} class="text-sm text-zinc-500 dark:text-zinc-400">{@last_action}</span>
        </div>
      </div>
    </div>
    """
  end

  # --- Container Panel ---

  def container_panel(%{has_container: false} = assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center">
      <p class="text-sm text-zinc-400 dark:text-zinc-500">No container running</p>
    </div>
    """
  end

  def container_panel(assigns) do
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
        <pre class="flex-1 px-4 py-3 text-xs font-mono overflow-auto whitespace-pre-wrap bg-zinc-100 dark:bg-zinc-950 text-zinc-800 dark:text-green-400 min-h-[200px]">{@logs}</pre>
      </div>
    </div>
    """
  end

  # --- Context Panel (right sidebar) ---

  def context_panel(assigns) do
    ~H"""
    <aside class="hidden lg:flex w-80 flex-none border-l border-zinc-200 dark:border-zinc-700/80 flex-col bg-zinc-50 dark:bg-zinc-900/50 overflow-y-auto">
      <div class="px-4 py-3 border-b border-zinc-200 dark:border-zinc-700/80">
        <h3 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">Agent Context</h3>
      </div>

      <%!-- Name (click to edit) --%>
      <div class="px-4 py-3 border-b border-zinc-200 dark:border-zinc-700/80">
        <form :if={@editing_name} phx-submit="rename_agent" phx-click-away="cancel_rename" class="flex items-center gap-2">
          <input type="text" name="name" value={@agent.name} autofocus phx-mounted={JS.dispatch("focus")}
            class="flex-1 rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-1.5 text-sm
                   text-zinc-900 dark:text-zinc-100 focus:outline-none focus:ring-1 focus:ring-violet-500/30" />
          <button type="submit" class="text-xs text-violet-600 dark:text-violet-400 hover:underline flex-none">Save</button>
        </form>
        <div :if={!@editing_name} phx-click="start_rename" class="cursor-pointer group flex items-center gap-2">
          <span class="text-sm font-medium text-zinc-900 dark:text-zinc-100">{@agent.name}</span>
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3 h-3 text-zinc-300 dark:text-zinc-600 opacity-0 group-hover:opacity-100 transition-opacity">
            <path d="M13.488 2.513a1.75 1.75 0 0 0-2.475 0L6.75 6.774a2.75 2.75 0 0 0-.596.892l-.848 2.047a.75.75 0 0 0 .98.98l2.047-.848a2.75 2.75 0 0 0 .892-.596l4.261-4.262a1.75 1.75 0 0 0 0-2.474Z" />
            <path d="M4.75 3.5c-.69 0-1.25.56-1.25 1.25v6.5c0 .69.56 1.25 1.25 1.25h6.5c.69 0 1.25-.56 1.25-1.25V9A.75.75 0 0 1 14 9v2.25A2.75 2.75 0 0 1 11.25 14h-6.5A2.75 2.75 0 0 1 2 11.25v-6.5A2.75 2.75 0 0 1 4.75 2H7a.75.75 0 0 1 0 1.5H4.75Z" />
          </svg>
        </div>
      </div>

      <%!-- Agent Info --%>
      <div class="px-4 py-3 space-y-2">
        <h4 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">Info</h4>
        <div class="space-y-1.5 text-xs">
          <div class="flex justify-between">
            <span class="text-zinc-400">Status</span>
            <span class="font-medium text-zinc-700 dark:text-zinc-300">{@agent.status}</span>
          </div>
          <div class="flex justify-between">
            <span class="text-zinc-400">Tool calls</span>
            <span class="font-medium text-zinc-700 dark:text-zinc-300">{@agent.tool_calls}</span>
          </div>
          <div class="flex justify-between">
            <span class="text-zinc-400">Errors</span>
            <span class={"font-medium #{if @agent.errors > 0, do: "text-red-500", else: "text-zinc-700 dark:text-zinc-300"}"}>{@agent.errors}</span>
          </div>
          <div :if={@agent[:started_at]} class="flex justify-between">
            <span class="text-zinc-400">Started</span>
            <span class="text-zinc-700 dark:text-zinc-300">{time_ago(@agent.started_at)}</span>
          </div>
        </div>
      </div>

      <%!-- Container section --%>
      <div :if={@has_container} class="border-t border-zinc-200 dark:border-zinc-700/80">
        <div class="px-4 py-3">
          <div class="flex items-center justify-between mb-2">
            <h4 class="text-xs font-semibold uppercase tracking-wider text-zinc-500">Container</h4>
            <button phx-click="refresh_container" class="text-xs text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors">
              Refresh
            </button>
          </div>
          <div :if={@container_env} class="mb-2">
            <pre class="text-[10px] font-mono text-zinc-500 dark:text-zinc-500 overflow-x-auto whitespace-pre-wrap max-h-32 overflow-y-auto">{@container_env}</pre>
          </div>
          <div :if={@container_logs != ""}>
            <pre class="text-[10px] font-mono bg-zinc-100 dark:bg-zinc-950 text-zinc-800 dark:text-green-400 rounded p-2 overflow-auto whitespace-pre-wrap max-h-40">{@container_logs}</pre>
          </div>
        </div>
      </div>
    </aside>
    """
  end
end
