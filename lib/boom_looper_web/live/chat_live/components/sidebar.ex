defmodule BoomLooperWeb.Live.ChatLive.Components.Sidebar do
  @moduledoc "Sidebar components for chat_live: sidebar, service_item, volume_item, agent_list_item, new_agent_screen."
  use Phoenix.Component

  import BoomLooperWeb.Components.Sidebar, only: [
    status_dot: 1, service_dot: 1, service_detail: 1, first_host_port: 1, thinking_word: 1
  ]
  import BoomLooperWeb.Components.Source.Local.SyncCard, only: [sync_card: 1]
  import BoomLooperWeb.Live.ChatLive.Components.Formatters, only: [
    service_status_text: 1, exit_reason: 1, derive_volume_description: 1
  ]

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
end
