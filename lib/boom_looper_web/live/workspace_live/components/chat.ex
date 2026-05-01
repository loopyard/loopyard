defmodule BoomLooperWeb.Live.WorkspaceLive.Components.Chat do
  @moduledoc "Chat panel components: agent_view, agent_header, chat_panel, thinking_indicator, container_panel."
  use Phoenix.Component

  import BoomLooperWeb.Components.Common, only: [dot: 1, control_btn: 1]
  import BoomLooperWeb.Components.Sidebar, only: [status_dot: 1, agent_display_status: 1]
  import BoomLooperWeb.Components.Breadcrumbs, only: [breadcrumbs: 1]
  import BoomLooperWeb.Live.WorkspaceLive.Messages, only: [chat_msg: 1, streaming_bubble: 1]
  import BoomLooperWeb.Live.WorkspaceLive.Components.Formatters, only: [time_ago: 1]
  import BoomLooperWeb.Live.WorkspaceLive.Components.ContextPanel, only: [context_panel: 1]


  # Build the breadcrumb trail for this workspace view.
  #   Boom Looper / {project.name or workspace.name} / {branch if not main}
  # Last crumb has `nil` path so the Breadcrumbs component renders it
  # as the current page (no link, aria-current="page").
  defp workspace_crumbs(assigns) do
    entry = assigns.workspace_entry
    branch_crumb? = entry && !entry[:is_main]

    crumbs = [{"Boom Looper", "/"}]

    crumbs =
      if assigns.project do
        crumbs ++ [{assigns.workspace.name, "/projects/#{assigns.project.id}"}]
      else
        crumbs ++ [{assigns.workspace.name, nil}]
      end

    if branch_crumb? do
      crumbs ++ [{entry.name, nil}]
    else
      # Re-mark last crumb as current page (path = nil)
      List.update_at(crumbs, -1, fn {label, _} -> {label, nil} end)
    end
  end

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

    crumbs = workspace_crumbs(assigns)
    mobile_crumbs = Enum.take(crumbs, -1)

    assigns =
      assigns
      |> assign(:back_kind, back_kind)
      |> assign(:back_target, back_target)
      |> assign(:back_label, back_label)
      |> assign(:crumbs, crumbs)
      |> assign(:mobile_crumbs, mobile_crumbs)

    ~H"""
    <header class="flex-none h-14 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center justify-between px-4 md:px-5">
      <div class="flex items-center gap-3 min-w-0">
        <.link
          :if={@back_kind == :patch}
          patch={@back_target}
          class="md:hidden -ml-1 inline-flex items-center gap-1 px-2 py-1 rounded-md text-base font-medium text-violet-600 dark:text-violet-400 hover:bg-violet-50 dark:hover:bg-violet-500/10 active:bg-violet-100 dark:active:bg-violet-500/20 transition-colors flex-none min-w-0"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5 flex-none">
            <path fill-rule="evenodd" d="M17 10a.75.75 0 0 1-.75.75H5.612l4.158 3.96a.75.75 0 1 1-1.04 1.08l-5.5-5.25a.75.75 0 0 1 0-1.08l5.5-5.25a.75.75 0 1 1 1.04 1.08L5.612 9.25H16.25A.75.75 0 0 1 17 10Z" clip-rule="evenodd" />
          </svg>
          <span class="truncate">{@back_label}</span>
        </.link>
        <.link
          :if={@back_kind == :navigate}
          navigate={@back_target}
          class="md:hidden -ml-1 inline-flex items-center gap-1 px-2 py-1 rounded-md text-base font-medium text-violet-600 dark:text-violet-400 hover:bg-violet-50 dark:hover:bg-violet-500/10 active:bg-violet-100 dark:active:bg-violet-500/20 transition-colors flex-none min-w-0"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5 flex-none">
            <path fill-rule="evenodd" d="M17 10a.75.75 0 0 1-.75.75H5.612l4.158 3.96a.75.75 0 1 1-1.04 1.08l-5.5-5.25a.75.75 0 0 1 0-1.08l5.5-5.25a.75.75 0 1 1 1.04 1.08L5.612 9.25H16.25A.75.75 0 0 1 17 10Z" clip-rule="evenodd" />
          </svg>
          <span class="truncate">{@back_label}</span>
        </.link>
        <.breadcrumbs crumbs={@crumbs} class="hidden md:flex" />
        <.breadcrumbs crumbs={@mobile_crumbs} class="md:hidden" />
        <BoomLooperWeb.Components.AppHeader.iex_indicator :if={@iex_session.level} session={@iex_session} />
      </div>
      <div class="flex items-center gap-2 flex-none hidden md:flex">
        <.link
          navigate={Path.join("/remote", @base_path)}
          class="focus-ring inline-flex items-center px-2 py-1 text-sm font-medium text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-100 transition-colors rounded"
        >
          Remote
        </.link>
        <.link
          navigate="/system"
          class="focus-ring inline-flex items-center px-2 py-1 text-sm font-medium text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-100 transition-colors rounded"
        >
          System
        </.link>
      </div>
    </header>
    """
  end

  # --- Agent View ---

  def agent_view(assigns) do
    ~H"""
    <div class="flex-1 flex min-h-0">
      <%!-- Main content: hidden on mobile when viewing context panel --%>
      <div class={["flex-1 flex flex-col min-w-0 min-h-0", if(@tab == :context_panel, do: "hidden lg:flex", else: "flex")]}>
        <.agent_header agent={@selected_agent} tab={@tab} has_container={@has_container} base_path={@base_path} />
        <.chat_panel :if={@tab in [:chat, :context_panel]} messages={@messages} streaming_text={@streaming_text} agent={@selected_agent} workspace_id={@workspace.id} host={@host} thinking_word={@thinking_word} />
        <.container_panel :if={@tab == :container} env={@container_env} logs={@container_logs} log_service={@container_log_service} has_container={@has_container} />
      </div>
      <%!-- Context panel: always visible on lg+, full-screen on mobile when :context_panel --%>
      <div class={if @tab == :context_panel, do: "flex-1 lg:w-80 lg:flex-none", else: ""}>
        <.context_panel agent={@selected_agent} has_container={@has_container} container_env={@container_env} container_logs={@container_logs} editing_name={@editing_name} mobile={@tab == :context_panel} />
      </div>
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
          <.dot color={status_dot(@agent.status)} />
          <span class="text-base font-semibold text-zinc-900 dark:text-zinc-100 truncate">{@agent.name}</span>
          <span :if={@agent[:last_activity_at]} class="text-xs text-zinc-400 dark:text-zinc-500 hidden sm:block flex-none">
            {time_ago(@agent[:last_activity_at])}
          </span>
        </div>
        <div class="flex items-center gap-1 md:gap-2 flex-none">
          <%!--
            Mobile-only navigation into the Agent Context pane. On lg+
            the pane is always visible in the right rail, so we hide
            the link. Mirrors the "Menu" back-link on the left that
            returns to the sidebar — sidebar → chat → context.
          --%>
          <.link patch={"#{@base_path}/agents/#{@agent.id}/context"}
            class="lg:hidden text-xs font-medium text-zinc-500 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-700 rounded-md px-2 py-1"
            aria-label="Agent context">
            Info
          </.link>
          <%!-- Two primary actions, mutually exclusive. Stop shows while
               the agent is Ready or Thinking; Start shows while it's
               Sleeping or Crashed. (No "Restart CLI" — Stop + Start
               gives the same effect by replaying from the log.)
               Matches the service-control button style for visual
               consistency across the workspace. --%>
          <.control_btn :if={agent_display_status(@agent) in [:ready, :thinking]}
            phx-click="stop_agent" phx-value-id={@agent.id}>
            Stop
          </.control_btn>
          <.control_btn :if={agent_display_status(@agent) in [:sleeping, :crashed]}
            variant={:primary} phx-click="start_agent" phx-value-id={@agent.id}>
            Start
          </.control_btn>
          <.control_btn :if={agent_display_status(@agent) in [:sleeping, :crashed]}
            phx-click="remove_agent" phx-value-id={@agent.id}>
            Remove
          </.control_btn>
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
        <.link patch={"#{@base_path}/agents/#{@agent.id}/context"}
          class={"lg:hidden px-3 py-1.5 text-xs font-medium border-b-2 transition-colors #{if @tab == :context_panel, do: "border-violet-500 text-violet-600 dark:text-violet-400", else: "border-transparent text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"}"}>
          Info
        </.link>
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
          <.chat_msg msg={msg} idx={idx} agent_id={@agent.id} workspace_id={@workspace_id} host={@host} />
        </div>
        <.streaming_bubble :if={@streaming_text != ""} text={@streaming_text} />
        <.thinking_indicator :if={@agent.status == :thinking && @streaming_text == ""} messages={@messages} word={@thinking_word} />
        <div id="scroll-anchor" aria-hidden="true"></div>
      </div>
      <div id="chat-form-wrapper" phx-update="ignore" class="flex-none border-t border-zinc-200 dark:border-zinc-700/80 p-3 md:p-4">
        <form id="chat-form" phx-submit="send_message" phx-hook="ChatForm" class="flex gap-2">
          <textarea
            name="message" id="chat-input" rows="1"
            placeholder="Type a message..."
            autocomplete="off"
            class="flex-1 rounded-xl border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-4 py-2.5 text-base
                   text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 resize-none
                   focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400"></textarea>
          <button type="submit"
            class="rounded-xl bg-violet-600 hover:bg-violet-700 px-4 py-2.5 text-base font-medium text-white transition-colors flex-none">
            Send
          </button>
        </form>
      </div>
    </div>
    """
  end

  def thinking_indicator(assigns) do
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
        <div class="flex items-center gap-2">
          <div class="flex gap-1 flex-none">
            <div class="w-1.5 h-1.5 rounded-full bg-violet-400 animate-bounce" style="animation-delay: 0ms"></div>
            <div class="w-1.5 h-1.5 rounded-full bg-violet-400 animate-bounce" style="animation-delay: 150ms"></div>
            <div class="w-1.5 h-1.5 rounded-full bg-violet-400 animate-bounce" style="animation-delay: 300ms"></div>
          </div>
          <span class="text-base text-violet-500 dark:text-violet-400 flex-none">{@word}...</span>
        </div>
        <p :if={@last_action} class="text-xs text-zinc-500 dark:text-zinc-400 mt-1 truncate">{@last_action}</p>
      </div>
    </div>
    """
  end

  # --- Container Panel ---

  def container_panel(%{has_container: false} = assigns) do
    ~H"""
    <div class="flex-1 flex items-center justify-center">
      <p class="text-base text-zinc-400 dark:text-zinc-500">No container running</p>
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

end
