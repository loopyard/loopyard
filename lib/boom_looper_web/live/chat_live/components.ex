defmodule BoomLooperWeb.Live.ChatLive.Components do
  @moduledoc """
  Render components for the chat LiveView — extracted from
  `BoomLooperWeb.ChatLive` to keep that file thin.

  Contains all `defp` component functions that were previously in
  `chat_live.ex`: sidebar, agent views, service log views, container
  panels, and supporting formatting helpers.

  This module is `import`ed by the parent LiveView so the function
  component calls in `render/1` continue to work unchanged.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  import BoomLooperWeb.Components.LogViewer
  import BoomLooperWeb.Components.Sidebar, only: [
    status_dot: 1, service_dot: 1, service_detail: 1, first_host_port: 1, thinking_word: 1
  ]
  import BoomLooperWeb.Components.Source.Local.SyncCard, only: [sync_card: 1]
  import BoomLooperWeb.Live.ChatLive.Messages, only: [chat_msg: 1, streaming_bubble: 1]

  # --- Header ---

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

  # --- Sidebar ---

  def sidebar(assigns) do
    base_path = if assigns.project do
      "/projects/#{assigns.project.id}/workspaces/#{assigns.workspace_entry.id}"
    else
      "/projects/#{assigns.workspace_id}/workspaces/#{assigns.workspace_id}"
    end
    assigns = assign(assigns, :base_path, base_path)

    ~H"""
    <%!-- On mobile: full-width when visible (index/new), hidden when agent/service selected.
         On md+: always visible as a fixed-width sidebar. --%>
    <aside class={[
      "flex-none border-r border-zinc-200 dark:border-zinc-700/80 flex flex-col bg-zinc-50 dark:bg-zinc-900/50",
      "w-full md:w-80",
      if(@live_action in [:chat, :container, :service, :console, :services] || @selected_id || @selected_service,
        do: "hidden md:flex",
        else: "flex")
    ]}>
      <div class="flex-none p-3 border-b border-zinc-200 dark:border-zinc-700/80">
        <.link
          navigate={"#{@base_path}/new"}
          class="w-full inline-flex items-center justify-center gap-1.5 rounded-lg border border-zinc-200 dark:border-zinc-700 px-3.5 py-2 text-sm font-medium text-zinc-600 dark:text-zinc-400
                 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
            <path d="M8.75 3.75a.75.75 0 0 0-1.5 0v3.5h-3.5a.75.75 0 0 0 0 1.5h3.5v3.5a.75.75 0 0 0 1.5 0v-3.5h3.5a.75.75 0 0 0 0-1.5h-3.5v-3.5Z" />
          </svg>
          New Agent
        </.link>
      </div>
      <div class="flex-1 overflow-y-auto">
        <%!-- Sync section - only for Local workspaces --%>
        <div :if={@is_local_source?} class="px-3 pt-3 pb-1">
          <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 font-semibold mb-1.5">Local sync</div>
          <.sync_card workspace_id={@workspace_id} sync={@sync_status || %{}} />
        </div>

        <%!-- Agents section - always show header --%>
        <div class="px-3 pt-3 pb-1">
          <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 font-semibold mb-1.5">Agents</div>
          <div :if={@agents != []} class="space-y-0.5">
            <.agent_list_item :for={agent <- @agents} agent={agent} selected={@selected_id == agent.id} />
          </div>
          <p :if={@agents == []} class="text-xs text-zinc-400 dark:text-zinc-500 py-1">No agents</p>
        </div>

        <%!-- Services section - only show when services exist or still loading --%>
        <div :if={@service_statuses != [] || !@services_loaded} class="px-3 pt-3 pb-1">
          <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 font-semibold mb-1.5">Services</div>
          <div :if={@service_statuses != []} class="space-y-0.5">
            <.service_item :for={svc <- @service_statuses} svc={svc} base_path={@base_path} selected={@selected_service == svc.name} host={@host} />
          </div>
          <p :if={!@services_loaded} class="text-xs text-zinc-400 dark:text-zinc-500 py-1">Loading...</p>
        </div>

        <%!-- Volumes section - always show header --%>
        <div class="px-3 pt-3 pb-1">
          <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 font-semibold mb-1.5">Volumes</div>
          <div :if={@volumes != []} class="space-y-0.5">
            <.volume_item :for={vol <- @volumes} vol={vol} base_path={@base_path} />
          </div>
          <p :if={!@volumes_loaded} class="text-xs text-zinc-400 dark:text-zinc-500 py-1">Loading...</p>
          <p :if={@volumes_loaded && @volumes == []} class="text-xs text-zinc-400 dark:text-zinc-500 py-1">No volumes</p>
        </div>
      </div>
    </aside>
    """
  end

  # --- New Agent Screen ---

  def new_agent_screen(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto p-6 md:p-8">
      <div class="max-w-2xl mx-auto">
        <h2 class="text-xl font-semibold text-zinc-900 dark:text-zinc-100 mb-1">New Agent</h2>
        <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-6">Launch a new agent to work on this project.</p>

        <form phx-submit="spawn_agent">
          <button type="submit"
            class="rounded-xl bg-zinc-900 dark:bg-zinc-100 px-6 py-3 text-sm font-medium text-white dark:text-zinc-900
                   hover:bg-zinc-700 dark:hover:bg-zinc-300 transition-colors">
            Launch Agent
          </button>
        </form>

        <div class="mt-6">
          <.link navigate={@base_path} class="text-sm text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 transition-colors">Cancel</.link>
        </div>
      </div>
    </div>
    """
  end

  # --- Sidebar items ---

  def service_item(assigns) do
    first_port = first_host_port(assigns.svc.ports)
    assigns = assign(assigns, :first_port, first_port)

    ~H"""
    <div class={"flex items-center gap-2 px-2 py-1.5 rounded text-sm transition-colors #{if @selected, do: "bg-white dark:bg-zinc-800 shadow-sm", else: "hover:bg-white/60 dark:hover:bg-zinc-800/40"}"}>
      <.link navigate={"#{@base_path}/services/#{@svc.name}"} class="flex items-center gap-2 min-w-0 flex-1">
        <div class={"w-1.5 h-1.5 rounded-full flex-none #{service_dot(@svc)}"}></div>
        <span class="truncate text-zinc-600 dark:text-zinc-400">{@svc.name}</span>
      </.link>
      <a :if={@first_port && @svc.status == :running} href={"http://#{@host}:#{@first_port}"} target="_blank"
        class="text-[10px] text-violet-500 hover:text-violet-400 font-mono ml-auto flex-none transition-colors">
        :{@first_port}
      </a>
      <span :if={service_status_text(@svc)} class="text-[10px] text-blue-400 ml-auto flex-none">{service_status_text(@svc)}</span>
      <span :if={!service_status_text(@svc) && !@first_port && @svc.status == :running} class="text-[10px] text-zinc-400 dark:text-zinc-500 ml-auto font-mono truncate max-w-[100px]">{service_detail(@svc)}</span>
      <span :if={@svc.status == :crashed && @svc.exit_info} class="text-[10px] text-red-500 ml-auto truncate max-w-[140px]">{exit_reason(@svc.exit_info)}</span>
    </div>
    """
  end

  def volume_item(assigns) do
    # Use description from volume_info if available, otherwise derive from name
    description = assigns.vol[:description] || derive_volume_description(assigns.vol.name)
    service = assigns.vol[:service]

    assigns = assigns
    |> assign(:description, description)
    |> assign(:service, service)

    ~H"""
    <div class="flex items-center gap-2 px-2 py-1.5 rounded text-sm transition-colors hover:bg-white/60 dark:hover:bg-zinc-800/40">
      <div class="flex items-center gap-2 min-w-0 flex-1">
        <div class="w-1.5 h-1.5 rounded-full flex-none bg-blue-400"></div>
        <div class="min-w-0 flex-1">
          <span class="truncate text-zinc-600 dark:text-zinc-400 block">{@description}</span>
          <span :if={@service && @service != "workspace"} class="text-[10px] text-zinc-400 dark:text-zinc-500">{@service}</span>
        </div>
      </div>
      <span :if={@vol[:size]} class="text-[10px] text-zinc-400 dark:text-zinc-500 font-mono flex-none">{@vol.size}</span>
    </div>
    """
  end

  def agent_list_item(assigns) do
    ~H"""
    <button
      phx-click="select_agent"
      phx-value-id={@agent.id}
      class={"w-full text-left px-2 py-1.5 rounded text-sm transition-colors
             #{if @selected, do: "bg-white dark:bg-zinc-800 shadow-sm", else: "hover:bg-white/60 dark:hover:bg-zinc-800/40"}"}
    >
      <div class="flex items-center gap-2">
        <div class={"w-1.5 h-1.5 rounded-full flex-none #{status_dot(@agent.status)}"}></div>
        <span class="truncate text-zinc-600 dark:text-zinc-400">{@agent.name}</span>
        <span :if={@agent.status == :booting} class="text-xs text-violet-400 flex-none">booting</span>
        <span :if={@agent.status == :thinking} class="text-xs text-amber-500 flex-none">{thinking_word(@agent.id)}</span>
        <span :if={@agent.status == :destroying} class="text-xs text-red-400 flex-none">destroying</span>
        <span :if={@agent.status in [:stopped, :crashed]}
          phx-click="remove_agent" phx-value-id={@agent.id}
          class="ml-auto text-xs text-zinc-400 hover:text-red-500 dark:hover:text-red-400 flex-none transition-colors"
          title="Remove agent">
          &times;
        </span>
      </div>
      <div :if={@agent.status == :booting} class="mt-1 ml-[18px] text-xs text-zinc-400 dark:text-zinc-500 truncate">{@agent[:boot_status] || "Initializing..."}</div>
    </button>
    """
  end

  # --- Screens ---

  def booting_screen(assigns) do
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
        <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-4">{@status}</p>
        <details :if={@boot_log != []} class="text-left">
          <summary class="text-xs text-zinc-400 dark:text-zinc-500 cursor-pointer hover:text-zinc-600 dark:hover:text-zinc-300">Boot log</summary>
          <div class="mt-2 bg-zinc-50 dark:bg-zinc-800 rounded-lg p-3 text-xs font-mono text-zinc-500 dark:text-zinc-400 space-y-0.5 max-h-48 overflow-y-auto">
            <p :for={line <- @boot_log}>{line}</p>
          </div>
        </details>
      </div>
    </div>
    """
  end

  def empty_state(assigns) do
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
      <div class="flex-none border-t border-zinc-200 dark:border-zinc-700/80 p-3 md:p-4 safe-area-bottom">
        <form id="chat-form" phx-submit="send_message" phx-hook="ChatForm" class="flex gap-2">
          <textarea
            name="message" id="chat-input" rows="1"
            placeholder={if @agent.status == :thinking, do: "Agent is #{thinking_word(@agent.id)}...", else: "Type a message..."}
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

  # --- Service Log Views ---

  def service_log_view(assigns) do
    svc = Enum.find(assigns.service_statuses, &(&1.name == assigns.service_name))
    first_port = if svc, do: first_host_port(svc.ports), else: nil
    assigns = assign(assigns, svc: svc, first_port: first_port)

    ~H"""
    <div class="flex-1 flex flex-col min-h-0">
      <div class="flex-none border-b border-zinc-200 dark:border-zinc-700/80 px-4 md:px-5 h-12 flex items-center gap-3">
        <div :if={@svc} class={"w-2 h-2 rounded-full flex-none #{service_dot(@svc)}"}></div>
        <span class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">{@service_name}</span>
        <span :if={@svc} class="text-xs text-zinc-400 dark:text-zinc-500 font-mono">{service_detail(@svc)}</span>
        <a :if={@first_port} href={"http://#{@host}:#{@first_port}"} target="_blank"
          class="text-xs font-mono text-violet-500 hover:text-violet-400 transition-colors">
          {@host}:{@first_port}
        </a>
        <div class="ml-auto flex items-center gap-3">
          <.link navigate={"#{@base_path}/services/#{@service_name}/console"}
            class="text-xs font-medium text-zinc-500 dark:text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200 transition-colors">
            Console
          </.link>
          <button phx-click="spawn_service_agent" phx-value-service_name={@service_name}
            class="text-xs font-medium text-violet-600 dark:text-violet-400 hover:text-violet-500 transition-colors">
            + Debug Agent
          </button>
        </div>
      </div>
      <.log_panel id="service-logs" content={@logs} />
    </div>
    """
  end

  def console_view(assigns) do
    ssh_cmd = if assigns.container do
      "ssh -p #{BoomLooper.SSHServer.port()} #{assigns.container}@localhost"
    end

    assigns = assign(assigns, :ssh_cmd, ssh_cmd)

    ~H"""
    <div class="flex-1 flex flex-col min-h-0">
      <div class="flex-none border-b border-zinc-200 dark:border-zinc-700/80 px-4 md:px-5 h-12 flex items-center gap-3">
        <span class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">{@service_name}</span>
        <span class="text-xs text-zinc-400 dark:text-zinc-500">console</span>
        <div :if={@ssh_cmd} class="ml-auto">
          <button id="copy-ssh" phx-hook="CopySource" data-source={@ssh_cmd}
            class="flex items-center gap-1.5 text-xs text-zinc-400 hover:text-zinc-300 transition-colors font-mono">
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5 copy-icon">
              <path d="M5.5 3.5A1.5 1.5 0 0 1 7 2h2.879a1.5 1.5 0 0 1 1.06.44l2.122 2.12a1.5 1.5 0 0 1 .439 1.061V9.5A1.5 1.5 0 0 1 12 11V8.621a3 3 0 0 0-.879-2.121L9 4.379A3 3 0 0 0 6.879 3.5H5.5Z" />
              <path d="M4 5a1.5 1.5 0 0 0-1.5 1.5v6A1.5 1.5 0 0 0 4 14h5a1.5 1.5 0 0 0 1.5-1.5V8.621a1.5 1.5 0 0 0-.44-1.06L7.94 5.439A1.5 1.5 0 0 0 6.878 5H4Z" />
            </svg>
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5 check-icon hidden text-green-400">
              <path fill-rule="evenodd" d="M12.416 3.376a.75.75 0 0 1 .208 1.04l-5 7.5a.75.75 0 0 1-1.154.114l-3-3a.75.75 0 0 1 1.06-1.06l2.353 2.353 4.493-6.74a.75.75 0 0 1 1.04-.207Z" clip-rule="evenodd" />
            </svg>
            SSH
          </button>
        </div>
      </div>
      <div
        :if={@container}
        id={"terminal-#{@container}"}
        phx-hook="Terminal"
        data-container={@container}
        phx-update="ignore"
        class="flex-1 bg-[#18181b] p-3"
      ></div>
      <div :if={!@container} class="flex-1 flex items-center justify-center">
        <p class="text-sm text-zinc-400">Service not running</p>
      </div>
    </div>
    """
  end

  def all_services_view(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col min-h-0">
      <div class="flex-none border-b border-zinc-200 dark:border-zinc-700/80 px-4 md:px-5 h-12 flex items-center">
        <span class="text-sm font-semibold text-zinc-900 dark:text-zinc-100">All Services</span>
      </div>
      <.log_multi_service logs={@all_service_logs} />
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

  # --- Formatting helpers ---

  def service_status_text(%{status: :running}), do: nil
  def service_status_text(%{status: :starting}), do: "starting"
  def service_status_text(%{status: :crashed}), do: nil
  def service_status_text(%{status: :stopped}), do: nil
  def service_status_text(_), do: nil

  def exit_reason(%{oom_killed: true}), do: "OOM killed"
  def exit_reason(%{error: error}) when is_binary(error), do: error
  def exit_reason(%{exit_code: 0}), do: "exited cleanly"
  def exit_reason(%{exit_code: 137}), do: "killed (SIGKILL)"
  def exit_reason(%{exit_code: 143}), do: "stopped (SIGTERM)"
  def exit_reason(%{exit_code: code}), do: "exit code #{code}"
  def exit_reason(_), do: "stopped"

  def time_ago(nil), do: ""

  def time_ago(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> "#{div(diff, 3600)}h ago"
    end
  end

  def derive_volume_description(name) do
    # Fallback for volumes without explicit description
    cond do
      String.contains?(name, "code") -> "Source code"
      String.contains?(name, "cache") -> "Build cache"
      String.contains?(name, "deps") -> "Dependencies"
      String.contains?(name, "postgres") -> "PostgreSQL data"
      String.contains?(name, "redis") -> "Redis data"
      String.contains?(name, "minio") -> "MinIO storage"
      true -> name
    end
  end
end
