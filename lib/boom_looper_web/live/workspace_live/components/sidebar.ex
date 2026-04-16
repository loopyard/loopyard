defmodule BoomLooperWeb.Live.WorkspaceLive.Components.Sidebar do
  @moduledoc "Sidebar components for workspace_live: sidebar, service_item, volume_item, agent_list_item, new_agent_screen."
  use Phoenix.Component

  import BoomLooperWeb.Components.Sidebar, only: [
    status_dot: 1, service_dot: 1, service_detail: 1, first_host_port: 1, thinking_word: 1
  ]
  import BoomLooperWeb.Live.WorkspaceLive.Components.Formatters, only: [
    service_status_text: 1, exit_reason: 1, derive_volume_description: 1
  ]

  # Always show sync for Local workspaces — even nil means "initializing"
  defp sync_relevant?(_), do: true

  # Container-related sync errors are "waiting" states, not real errors
  defp sync_waiting?(nil), do: true
  defp sync_waiting?(%{status: :errored, last_error: err}) when is_binary(err) do
    String.contains?(err, "container") or String.contains?(err, "No sync process")
  end
  defp sync_waiting?(%{status: s}) when s in [:starting, :unknown], do: true
  defp sync_waiting?(_), do: false

  defp sync_dot(nil), do: "bg-zinc-400 animate-pulse"
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
      if(@live_action in [:new, :chat, :container, :context_panel, :service, :console, :services, :volume, :volume_files_root, :volume_file, :volume_git, :sync] || @selected_id || @selected_service,
        do: "hidden md:flex",
        else: "flex")
    ]}>
      <div class="flex-none p-3 md:p-2 border-b border-zinc-200 dark:border-zinc-700/80">
        <.link
          navigate={"#{@base_path}/new"}
          class="focus-ring w-full inline-flex items-center justify-center gap-2 rounded-lg border border-zinc-200 dark:border-zinc-700 px-4 min-h-11 text-sm font-medium text-zinc-700 dark:text-zinc-300
                 hover:bg-zinc-100 dark:hover:bg-zinc-800 active:bg-zinc-200 dark:active:bg-zinc-700 transition-colors"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-4 h-4" aria-hidden="true">
            <path d="M8.75 3.75a.75.75 0 0 0-1.5 0v3.5h-3.5a.75.75 0 0 0 0 1.5h3.5v3.5a.75.75 0 0 0 1.5 0v-3.5h3.5a.75.75 0 0 0 0-1.5h-3.5v-3.5Z" />
          </svg>
          New Agent
        </.link>
      </div>
      <div class="flex-1 overflow-y-auto">
        <%!-- Agents --%>
        <div class="px-3 pt-3 md:pt-2 pb-1 md:pb-0.5">
          <div class="text-xs uppercase tracking-wider text-zinc-500 dark:text-zinc-400 font-semibold mb-1">Agents</div>
          <div :if={@agents != []} class="space-y-0.5">
            <.agent_list_item :for={agent <- @agents} agent={agent} selected={@selected_id == agent.id} />
          </div>
          <p :if={@agents == []} class="text-xs text-zinc-400 dark:text-zinc-500 py-1">No agents</p>
        </div>

        <%!-- Services --%>
        <div :if={@service_statuses != [] || !@services_loaded} class="px-3 pt-3 md:pt-2 pb-1 md:pb-0.5">
          <div class="flex items-center justify-between mb-1">
            <div class="text-xs uppercase tracking-wider text-zinc-500 dark:text-zinc-400 font-semibold">Services</div>
            <.services_toggle
              service_statuses={@service_statuses}
              services_busy={@services_busy}
            />
          </div>
          <div :if={@service_statuses != []} class="space-y-0.5">
            <.service_item :for={svc <- @service_statuses} svc={svc} base_path={@base_path} selected={@selected_service == svc.name} host={@host} workspace_id={@workspace_id} />
          </div>
          <p :if={!@services_loaded} class="text-xs text-zinc-400 dark:text-zinc-500 py-1">Loading...</p>
        </div>

        <%!-- Volumes --%>
        <div class="px-3 pt-3 md:pt-2 pb-1 md:pb-0.5">
          <div class="text-xs uppercase tracking-wider text-zinc-500 dark:text-zinc-400 font-semibold mb-1">Volumes</div>
          <div :if={@volumes != []} class="space-y-0.5">
            <.volume_item :for={vol <- @volumes} vol={vol} base_path={@base_path} />
          </div>
          <p :if={!@volumes_loaded} class="text-xs text-zinc-400 dark:text-zinc-500 py-1">Loading...</p>
          <p :if={@volumes_loaded && @volumes == []} class="text-xs text-zinc-400 dark:text-zinc-500 py-1">No volumes</p>
        </div>

        <%!--
          Host file sync — only relevant for Local source adapters. A
          GitHub-sourced workspace wouldn't have this row since code
          arrives via clone, not host filesystem sync.
        --%>
        <div :if={@is_local_source? && sync_relevant?(@sync_status)} class="px-3 pt-3 md:pt-2 pb-1 md:pb-0.5">
          <.link navigate={"#{@base_path}/sync"} class="flex items-center gap-2 px-2 py-1.5 rounded text-sm transition-colors hover:bg-white/60 dark:hover:bg-zinc-800/40">
            <div class={"w-1.5 h-1.5 rounded-full flex-none #{sync_dot(@sync_status)}"}></div>
            <span class="truncate text-zinc-600 dark:text-zinc-400">Host file sync</span>
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
        <p class="text-sm text-zinc-500 dark:text-zinc-400 mb-4">Start an agent with a task, or pick a preset below.</p>

        <form id="new-agent-form" phx-submit="spawn_agent_with_message" class="space-y-4">
          <textarea
            name="message" id="new-agent-input" rows="3"
            placeholder="What should this agent work on? (leave blank to start empty)"
            class="w-full rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-4 py-3 text-sm
                   text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 resize-none
                   focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400"
          ></textarea>
          <button type="submit"
            class="rounded-lg bg-zinc-900 dark:bg-zinc-100 px-5 py-2.5 text-sm font-medium text-white dark:text-zinc-900
                   hover:bg-zinc-700 dark:hover:bg-zinc-300 transition-colors">
            Launch Agent
          </button>
        </form>

        <div class="mt-6 pt-6 border-t border-zinc-200 dark:border-zinc-700/80">
          <div class="text-xs uppercase tracking-wider text-zinc-500 dark:text-zinc-400 font-semibold mb-3">Presets</div>
          <div class="space-y-2">
            <button phx-click="spawn_agent_with_message" phx-value-preset="setup"
              class="w-full text-left rounded-lg border border-zinc-200 dark:border-zinc-700 px-4 py-3 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors">
              <div class="text-sm font-medium text-zinc-900 dark:text-zinc-100">Set up dev environment</div>
              <div class="text-xs text-zinc-500 dark:text-zinc-400 mt-0.5">Write Dockerfile + docker-compose.yml, start services, install deps.</div>
            </button>
            <button phx-click="spawn_agent_with_message" phx-value-preset="debug"
              class="w-full text-left rounded-lg border border-zinc-200 dark:border-zinc-700 px-4 py-3 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors">
              <div class="text-sm font-medium text-zinc-900 dark:text-zinc-100">Debug failing services</div>
              <div class="text-xs text-zinc-500 dark:text-zinc-400 mt-0.5">Check service logs, diagnose errors, fix configuration.</div>
            </button>
            <button phx-click="spawn_agent_with_message" phx-value-preset="explore"
              class="w-full text-left rounded-lg border border-zinc-200 dark:border-zinc-700 px-4 py-3 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors">
              <div class="text-sm font-medium text-zinc-900 dark:text-zinc-100">Explore the codebase</div>
              <div class="text-xs text-zinc-500 dark:text-zinc-400 mt-0.5">Read files, search code, understand the project structure.</div>
            </button>
          </div>
        </div>

        <div class="mt-6">
          <.link navigate={@base_path} class="text-sm text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 transition-colors">Cancel</.link>
        </div>
      </div>
    </div>
    """
  end

  # --- Services cluster toggle ---

  defp any_running?(statuses), do: Enum.any?(statuses, &(&1.status == :running))

  attr :service_statuses, :list, required: true
  attr :services_busy, :atom, default: nil

  defp services_toggle(assigns) do
    assigns = assign(assigns, :running, any_running?(assigns.service_statuses))

    ~H"""
    <button
      type="button"
      phx-click={if @running, do: "stop_services", else: "start_services"}
      disabled={@services_busy != nil}
      title={cond do
        @services_busy == :starting -> "Starting services..."
        @services_busy == :stopping -> "Stopping services..."
        @running -> "Stop all services"
        true -> "Start all services"
      end}
      class={[
        "inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] font-medium transition-colors",
        "border border-zinc-200 dark:border-zinc-700",
        if(@services_busy, do: "text-zinc-400 dark:text-zinc-500 cursor-not-allowed",
          else: "text-zinc-500 dark:text-zinc-400 hover:bg-white dark:hover:bg-zinc-800")
      ]}
    >
      <%= cond do %>
        <% @services_busy == :starting -> %>
          <div class="w-1.5 h-1.5 rounded-full bg-blue-400 animate-pulse"></div>
          <span>Starting</span>
        <% @services_busy == :stopping -> %>
          <div class="w-1.5 h-1.5 rounded-full bg-amber-400 animate-pulse"></div>
          <span>Stopping</span>
        <% @running -> %>
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-2.5 h-2.5"><path d="M4.5 4.5a1 1 0 0 0-1 1v5a1 1 0 0 0 1 1h7a1 1 0 0 0 1-1v-5a1 1 0 0 0-1-1h-7Z" /></svg>
          <span>Stop</span>
        <% true -> %>
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-2.5 h-2.5"><path d="M4.5 3.5v9l7-4.5-7-4.5Z" /></svg>
          <span>Start</span>
      <% end %>
    </button>
    """
  end

  # --- Sidebar items ---

  def service_item(assigns) do
    # Prefer the registry-assigned host_port (stable) over observer's
    # svc.ports map (flaps to empty during container state transitions).
    # annotate_exposure in workspace_live writes :host_port from the
    # registry when available.
    host_port = Map.get(assigns.svc, :host_port) || first_host_port(assigns.svc.ports)
    assigns = assign(assigns, :first_port, host_port)

    ~H"""
    <div class={"grid grid-cols-[1fr_auto] items-center gap-2 px-2 py-1.5 md:py-1 min-h-11 md:min-h-0 rounded text-sm transition-colors #{if @selected, do: "bg-white dark:bg-zinc-800 shadow-sm", else: "hover:bg-white/60 dark:hover:bg-zinc-800/40"}"}>
      <.link navigate={"#{@base_path}/services/#{@svc.name}"} class="focus-ring flex items-center gap-2 min-w-0" aria-label={"Open #{@svc.name} service"}>
        <div class={"w-1.5 h-1.5 rounded-full flex-none #{service_dot(@svc)}"} aria-hidden="true"></div>
        <span class="truncate text-zinc-600 dark:text-zinc-400">{@svc.name}</span>
      </.link>
      <%!-- Trailing slot: ALWAYS rendered (even empty) at a min-width
           so the port button popping in can't push the service name.
           One slot holds one of: port action, status text, detail text,
           crash info — never stacked, never shifting. --%>
      <div class="flex items-center justify-end min-w-[92px] min-h-8">
        <.port_action
          :if={@first_port && Map.get(@svc, :container_port) && @svc.status == :running}
          host={@host}
          port={@first_port}
          svc={@svc}
        />
        <span :if={!@first_port && service_status_text(@svc)} class="text-xs text-blue-500 dark:text-blue-400">{service_status_text(@svc)}</span>
        <span :if={!@first_port && !service_status_text(@svc) && @svc.status == :running} class="text-xs text-zinc-500 dark:text-zinc-400 font-mono truncate max-w-[88px]">{service_detail(@svc)}</span>
        <span :if={@svc.status == :crashed && @svc.exit_info} class="text-xs text-red-500 truncate max-w-[88px]">{exit_reason(@svc.exit_info)}</span>
      </div>
    </div>
    """
  end

  # Single affordance per running service:
  #   * closed (loopback-only) → gray "open port" — click exposes + opens URL
  #   * open (0.0.0.0)         → green ":<port>"  — click just opens URL
  #
  # Closing an exposed port happens from /system/ports, not here.
  attr :host, :string, required: true
  attr :port, :integer, required: true
  attr :svc, :map, required: true

  def port_action(assigns) do
    exposed? = Map.get(assigns.svc, :exposed, false)

    assigns =
      assigns
      |> assign(:exposed?, exposed?)
      |> assign(:url, "http://#{assigns.host}:#{assigns.port}")

    label =
      if assigns.exposed?,
        do: "Open #{assigns.url} in a new tab — port is public",
        else: "Open #{assigns.url} in a new tab and expose it on 0.0.0.0"

    assigns = assign(assigns, :label, label)

    ~H"""
    <a
      href={@url}
      target="_blank"
      rel="noopener noreferrer"
      phx-click={unless @exposed?, do: "toggle_port_exposure"}
      phx-value-service={@svc.name}
      phx-value-container_port={Map.get(@svc, :container_port)}
      phx-value-expose="true"
      aria-label={@label}
      title={@label}
      class={[
        "focus-ring flex-none inline-flex items-center justify-center min-h-8 min-w-11 text-xs font-mono font-medium px-2 py-1 rounded transition-colors ml-auto",
        if(@exposed?,
          do: "bg-emerald-500/15 text-emerald-600 dark:text-emerald-400 hover:bg-emerald-500/25",
          else: "text-zinc-500 dark:text-zinc-400 hover:bg-zinc-200 dark:hover:bg-zinc-700")
      ]}
    >
      {if @exposed?, do: ":#{@port}", else: "open port"}
    </a>
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
    <.link
      navigate={"#{@base_path}/volumes/#{@vol.name}"}
      class="focus-ring flex items-center gap-2 px-2 py-1.5 md:py-1 min-h-11 md:min-h-0 rounded text-sm transition-colors hover:bg-white/60 dark:hover:bg-zinc-800/40"
      aria-label={"Open #{@description} volume"}
    >
      <div class="flex items-center gap-2 min-w-0 flex-1">
        <div class="w-1.5 h-1.5 rounded-full flex-none bg-blue-400" aria-hidden="true"></div>
        <div class="min-w-0 flex-1">
          <span class="truncate text-zinc-600 dark:text-zinc-400 block">{@description}</span>
          <span :if={@service && @service != "workspace"} class="text-xs text-zinc-500 dark:text-zinc-500">{@service}</span>
        </div>
      </div>
      <span :if={@vol[:size]} class="text-xs text-zinc-500 dark:text-zinc-400 font-mono flex-none">{@vol.size}</span>
    </.link>
    """
  end

  def agent_list_item(assigns) do
    ~H"""
    <div class="flex items-stretch gap-1">
      <button
        phx-click="select_agent"
        phx-value-id={@agent.id}
        aria-label={"Open agent #{@agent.name} (status: #{@agent.status})"}
        aria-current={if @selected, do: "true", else: "false"}
        class={"focus-ring flex-1 text-left px-2 py-1.5 md:py-1 min-h-11 md:min-h-0 rounded text-sm transition-colors
               #{if @selected, do: "bg-white dark:bg-zinc-800 shadow-sm", else: "hover:bg-white/60 dark:hover:bg-zinc-800/40"}"}
      >
        <div class="flex items-center gap-2">
          <div class={"w-1.5 h-1.5 rounded-full flex-none #{status_dot(@agent.status)}"} aria-hidden="true"></div>
          <span class="truncate text-zinc-600 dark:text-zinc-400">{@agent.name}</span>
          <span :if={@agent.status == :booting} class="text-xs text-violet-500 dark:text-violet-400 flex-none">booting</span>
          <span :if={@agent.status == :thinking} class="text-xs text-amber-600 dark:text-amber-500 flex-none">{thinking_word(@agent.id)}</span>
          <span :if={@agent.status == :destroying} class="text-xs text-red-500 dark:text-red-400 flex-none">destroying</span>
        </div>
        <div :if={@agent.status == :booting} class="mt-1 ml-[18px] text-xs text-zinc-500 dark:text-zinc-400 truncate">{@agent[:boot_status] || "Initializing..."}</div>
      </button>
      <button
        :if={@agent.status in [:stopped, :crashed]}
        phx-click="remove_agent"
        phx-value-id={@agent.id}
        aria-label={"Remove agent #{@agent.name}"}
        class="focus-ring inline-flex items-center justify-center min-w-11 min-h-11 md:min-w-8 md:min-h-8 text-zinc-400 hover:text-red-500 dark:hover:text-red-400 rounded transition-colors"
      >
        <span aria-hidden="true">&times;</span>
      </button>
    </div>
    """
  end
end
