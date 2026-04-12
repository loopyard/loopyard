defmodule BoomLooperWeb.Live.ChatLive.Components.Sidebar do
  @moduledoc "Sidebar components for chat_live: sidebar, service_item, volume_item, agent_list_item, new_agent_screen."
  use Phoenix.Component

  import BoomLooperWeb.Components.Sidebar, only: [
    status_dot: 1, service_dot: 1, service_detail: 1, first_host_port: 1, thinking_word: 1
  ]
  import BoomLooperWeb.Live.ChatLive.Components.Formatters, only: [
    service_status_text: 1, exit_reason: 1, derive_volume_description: 1
  ]

  defp sync_relevant?(nil), do: false
  defp sync_relevant?(_), do: true

  # Container-related sync errors are "waiting" states, not real errors
  defp sync_waiting?(%{status: :errored, last_error: err}) when is_binary(err) do
    String.contains?(err, "container") or String.contains?(err, "No sync process")
  end
  defp sync_waiting?(%{status: s}) when s in [:starting, :unknown], do: true
  defp sync_waiting?(_), do: false

  defp sync_dot(sync) do
    cond do
      sync_waiting?(sync) -> "bg-zinc-400 animate-pulse"
      match?(%{status: :running}, sync) -> "bg-emerald-500"
      match?(%{status: :paused}, sync) -> "bg-amber-400"
      match?(%{status: :errored}, sync) -> "bg-red-500"
      match?(%{status: :starting}, sync) -> "bg-blue-400 animate-pulse"
      true -> "bg-zinc-400"
    end
  end

  defp sync_label(sync) do
    cond do
      sync_waiting?(sync) -> "waiting"
      match?(%{status: :running}, sync) -> "running"
      match?(%{status: :paused}, sync) -> "paused"
      match?(%{status: :errored}, sync) -> "error"
      match?(%{status: :starting}, sync) -> "starting"
      true -> "stopped"
    end
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
      if(@live_action in [:chat, :container, :service, :console, :services, :volume, :sync] || @selected_id || @selected_service,
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
        <%!-- Agents --%>
        <div class="px-3 pt-3 pb-1">
          <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 font-semibold mb-1.5">Agents</div>
          <div :if={@agents != []} class="space-y-0.5">
            <.agent_list_item :for={agent <- @agents} agent={agent} selected={@selected_id == agent.id} />
          </div>
          <p :if={@agents == []} class="text-xs text-zinc-400 dark:text-zinc-500 py-1">No agents</p>
        </div>

        <%!-- Services --%>
        <div :if={@service_statuses != [] || !@services_loaded} class="px-3 pt-3 pb-1">
          <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 font-semibold mb-1.5">Services</div>
          <div :if={@service_statuses != []} class="space-y-0.5">
            <.service_item :for={svc <- @service_statuses} svc={svc} base_path={@base_path} selected={@selected_service == svc.name} host={@host} />
          </div>
          <p :if={!@services_loaded} class="text-xs text-zinc-400 dark:text-zinc-500 py-1">Loading...</p>
        </div>

        <%!-- Volumes --%>
        <div class="px-3 pt-3 pb-1">
          <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 font-semibold mb-1.5">Volumes</div>
          <div :if={@volumes != []} class="space-y-0.5">
            <.volume_item :for={vol <- @volumes} vol={vol} base_path={@base_path} />
          </div>
          <p :if={!@volumes_loaded} class="text-xs text-zinc-400 dark:text-zinc-500 py-1">Loading...</p>
          <p :if={@volumes_loaded && @volumes == []} class="text-xs text-zinc-400 dark:text-zinc-500 py-1">No volumes</p>
        </div>

        <%!-- Local sync — below volumes since it's about volume ↔ host file sync --%>
        <div :if={@is_local_source? && sync_relevant?(@sync_status)} class="px-3 pt-3 pb-1">
          <div class="text-[10px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 font-semibold mb-1.5">Local sync</div>
          <.link navigate={"#{@base_path}/sync"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm transition-colors hover:bg-white/60 dark:hover:bg-zinc-800/40">
            <div class={"w-1.5 h-1.5 rounded-full flex-none #{sync_dot(@sync_status)}"}></div>
            <span class="truncate text-zinc-600 dark:text-zinc-400">Sync</span>
            <span class="text-[10px] text-zinc-400 dark:text-zinc-500 ml-auto flex-none">{sync_label(@sync_status)}</span>
          </.link>
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
        <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-6">Choose an agent type for this workspace.</p>

        <div class="space-y-3">
          <button phx-click="spawn_agent" phx-value-type="blank"
            class="w-full text-left rounded-lg border border-zinc-200 dark:border-zinc-700 p-4 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors group">
            <div class="flex items-center gap-3">
              <div class="w-8 h-8 rounded-lg bg-zinc-100 dark:bg-zinc-800 flex items-center justify-center text-zinc-500 dark:text-zinc-400 group-hover:bg-violet-100 dark:group-hover:bg-violet-900/30 group-hover:text-violet-600 dark:group-hover:text-violet-400 transition-colors">
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
                  <path d="M1 8.849c0 1 .738 1.851 1.734 1.947L3 10.82v2.429a.75.75 0 0 0 1.28.53l1.92-1.92-.531-.53-.53-.53-1.39 1.39V10.5a.75.75 0 0 0-.663-.744C2.478 9.682 2 9.296 2 8.849c0-.853.597-1.595 1.453-1.853a.75.75 0 0 0 .527-.663c.188-2.18 2.032-3.833 4.2-3.833.725 0 1.41.18 2.006.505A.75.75 0 0 0 11.26 2.3a4.377 4.377 0 0 0-.973-.595A5.28 5.28 0 0 0 8.18 1C5.461 1 3.243 3.01 3.015 5.629 1.837 6.15 1 7.399 1 8.849Z" />
                  <path d="M7.657 6.768a.75.75 0 0 1 1.06 0l1.768 1.768a.75.75 0 1 1-1.06 1.06l-.488-.488v1.517a.75.75 0 0 1-1.5 0V9.108l-.488.488a.75.75 0 0 1-1.06-1.06l1.768-1.768Z" />
                  <path d="M12.568 4.235a3.033 3.033 0 0 1 .453 5.753.75.75 0 0 0-.553.665c-.003.046-.005.088-.009.125H11a.75.75 0 0 0 0 1.5h1.75c.69 0 1.25-.56 1.25-1.25 0-.046-.002-.091-.006-.135a4.533 4.533 0 0 0-.705-8.558 4.353 4.353 0 0 0-.835-.11.75.75 0 1 0-.086 1.498c.181.013.36.042.534.089l-.334-.577Z" />
                </svg>
              </div>
              <div>
                <div class="text-sm font-medium text-zinc-900 dark:text-zinc-100">Agent</div>
                <div class="text-xs text-zinc-500 dark:text-zinc-400">General-purpose. Has container tools. You tell it what to do.</div>
              </div>
            </div>
          </button>

          <button phx-click="spawn_agent" phx-value-type="setup"
            class="w-full text-left rounded-lg border border-zinc-200 dark:border-zinc-700 p-4 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors group">
            <div class="flex items-center gap-3">
              <div class="w-8 h-8 rounded-lg bg-zinc-100 dark:bg-zinc-800 flex items-center justify-center text-zinc-500 dark:text-zinc-400 group-hover:bg-amber-100 dark:group-hover:bg-amber-900/30 group-hover:text-amber-600 dark:group-hover:text-amber-400 transition-colors">
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4">
                  <path fill-rule="evenodd" d="M6.955 1.45A.5.5 0 0 1 7.452 1h1.096a.5.5 0 0 1 .497.45l.17 1.699c.484.12.94.312 1.356.562l1.321-.916a.5.5 0 0 1 .67.033l.774.775a.5.5 0 0 1 .034.67l-.916 1.32c.25.417.443.873.563 1.357l1.699.17a.5.5 0 0 1 .45.497v1.096a.5.5 0 0 1-.45.497l-1.699.17c-.12.484-.312.94-.562 1.356l.916 1.321a.5.5 0 0 1-.034.67l-.774.774a.5.5 0 0 1-.67.033l-1.32-.916c-.417.25-.874.443-1.357.563l-.17 1.699a.5.5 0 0 1-.497.45H7.452a.5.5 0 0 1-.497-.45l-.17-1.699a4.973 4.973 0 0 1-1.356-.562l-1.321.916a.5.5 0 0 1-.67-.033l-.775-.775a.5.5 0 0 1-.033-.67l.916-1.32a4.972 4.972 0 0 1-.563-1.357l-1.699-.17A.5.5 0 0 1 1 8.548V7.452a.5.5 0 0 1 .45-.497l1.699-.17c.12-.484.312-.94.562-1.356l-.916-1.321a.5.5 0 0 1 .033-.67l.775-.774a.5.5 0 0 1 .67-.033l1.32.916c.417-.25.874-.443 1.357-.563l.17-1.699ZM11 8a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z" clip-rule="evenodd" />
                </svg>
              </div>
              <div>
                <div class="text-sm font-medium text-zinc-900 dark:text-zinc-100">Setup Agent</div>
                <div class="text-xs text-zinc-500 dark:text-zinc-400">Examines the project and configures Dockerfile, docker-compose.yml, and services from scratch.</div>
              </div>
            </div>
          </button>
        </div>

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
    <.link navigate={"#{@base_path}/volumes/#{@vol.name}"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm transition-colors hover:bg-white/60 dark:hover:bg-zinc-800/40">
      <div class="flex items-center gap-2 min-w-0 flex-1">
        <div class="w-1.5 h-1.5 rounded-full flex-none bg-blue-400"></div>
        <div class="min-w-0 flex-1">
          <span class="truncate text-zinc-600 dark:text-zinc-400 block">{@description}</span>
          <span :if={@service && @service != "workspace"} class="text-[10px] text-zinc-400 dark:text-zinc-500">{@service}</span>
        </div>
      </div>
      <span :if={@vol[:size]} class="text-[10px] text-zinc-400 dark:text-zinc-500 font-mono flex-none">{@vol.size}</span>
    </.link>
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
