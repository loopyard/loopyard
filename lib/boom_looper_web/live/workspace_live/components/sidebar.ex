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
      <.workspace_header workspace_running={@workspace_running} services_busy={@services_busy} />

      <div class="flex-1 overflow-y-auto divide-y divide-zinc-200 dark:divide-zinc-800/80">
        <.sidebar_section label="Agents">
          <div :if={@agents != []} class="space-y-px">
            <.agent_list_item :for={agent <- @agents} agent={agent} selected={@selected_id == agent.id} />
          </div>
          <p :if={@agents == []} class="px-2 text-xs text-zinc-400 dark:text-zinc-500">No agents</p>
          <.link
            navigate={"#{@base_path}/new"}
            class="focus-ring mt-1 flex items-center gap-2 px-2 py-1.5 md:py-1 min-h-11 md:min-h-0 rounded text-sm text-violet-600 dark:text-violet-400 hover:bg-violet-50 dark:hover:bg-violet-500/10 transition-colors"
          >
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3.5 h-3.5 flex-none" aria-hidden="true">
              <path d="M8.75 3.75a.75.75 0 0 0-1.5 0v3.5h-3.5a.75.75 0 0 0 0 1.5h3.5v3.5a.75.75 0 0 0 1.5 0v-3.5h3.5a.75.75 0 0 0 0-1.5h-3.5v-3.5Z" />
            </svg>
            <span>New agent</span>
          </.link>
        </.sidebar_section>

        <.sidebar_section :if={@service_statuses != [] || !@services_loaded} label="Services">
          <div :if={@service_statuses != []} class="space-y-px">
            <.service_item :for={svc <- @service_statuses} svc={svc} base_path={@base_path} selected={@selected_service == svc.name} host={@host} workspace_id={@workspace_id} />
          </div>
          <p :if={!@services_loaded} class="px-2 text-xs text-zinc-400 dark:text-zinc-500">Loading...</p>
        </.sidebar_section>

        <%!-- Volumes + Host file sync live in one group. Sync is
             conceptually a volume data-source, and shoving it into its
             own labeled section created an orphan row with ~40px of
             dead space above it. --%>
        <.sidebar_section label="Volumes">
          <div :if={@volumes != []} class="space-y-px">
            <.volume_item :for={vol <- @volumes} vol={vol} base_path={@base_path} />
          </div>
          <p :if={!@volumes_loaded} class="px-2 text-xs text-zinc-400 dark:text-zinc-500">Loading...</p>
          <p :if={@volumes_loaded && @volumes == []} class="px-2 text-xs text-zinc-400 dark:text-zinc-500">No volumes</p>
          <.link
            :if={@is_local_source? && sync_relevant?(@sync_status)}
            navigate={"#{@base_path}/sync"}
            class="focus-ring mt-px flex items-center gap-2 px-2 py-1.5 md:py-1 min-h-11 md:min-h-0 rounded text-sm transition-colors hover:bg-white/60 dark:hover:bg-zinc-800/40"
          >
            <div class={"w-1.5 h-1.5 rounded-full flex-none #{sync_dot(@sync_status)}"} aria-hidden="true"></div>
            <span class="truncate text-zinc-600 dark:text-zinc-400">Host file sync</span>
          </.link>
        </.sidebar_section>
      </div>
    </aside>
    """
  end

  # Every group shares the exact same vertical rhythm. Previously each
  # section set its own padding and the visual beat drifted — most
  # obvious where "Host file sync" sat in its own orphan section with
  # ~40px of dead space around it.
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp sidebar_section(assigns) do
    ~H"""
    <section class="px-3 py-3 md:py-2">
      <h3 class="text-xs uppercase tracking-wider text-zinc-500 dark:text-zinc-400 font-semibold mb-1.5 md:mb-1 px-2">
        {@label}
      </h3>
      {render_slot(@inner_block)}
    </section>
    """
  end

  # Primary sidebar header: workspace state + Start/Stop. This is the
  # highest-priority thing a user needs to see/act on, so it goes at
  # the top where the "New Agent" button used to be. The New Agent
  # link moved down into the Agents section where it belongs
  # contextually.
  attr :workspace_running, :boolean, required: true
  attr :services_busy, :atom, default: nil

  defp workspace_header(assigns) do
    {label, dot_class} =
      cond do
        assigns.services_busy == :starting -> {"Starting…", "bg-blue-400 animate-pulse"}
        assigns.services_busy == :stopping -> {"Stopping…", "bg-amber-400 animate-pulse"}
        assigns.workspace_running -> {"Running", "bg-emerald-500"}
        true -> {"Stopped", "bg-zinc-400"}
      end

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:dot_class, dot_class)

    ~H"""
    <div class="flex-none border-b border-zinc-200 dark:border-zinc-700/80 px-3 py-2.5 md:py-2 flex items-center gap-2">
      <div class="flex items-center gap-2 min-w-0 flex-1">
        <div class={"w-2 h-2 rounded-full flex-none #{@dot_class}"} aria-hidden="true"></div>
        <span class="text-sm font-medium text-zinc-700 dark:text-zinc-200 truncate">Workspace {@label}</span>
      </div>
      <button
        :if={@workspace_running && !@services_busy}
        type="button"
        phx-click="shutdown_workspace"
        aria-label="Stop workspace"
        class="focus-ring inline-flex items-center gap-1.5 rounded-md px-3 min-h-9 md:min-h-8 text-xs font-medium border border-zinc-200 dark:border-zinc-700 text-zinc-700 dark:text-zinc-200 hover:bg-white dark:hover:bg-zinc-800 transition-colors"
      >
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3 h-3" aria-hidden="true">
          <path d="M4.5 4.5a1 1 0 0 0-1 1v5a1 1 0 0 0 1 1h7a1 1 0 0 0 1-1v-5a1 1 0 0 0-1-1h-7Z" />
        </svg>
        Stop
      </button>
      <button
        :if={!@workspace_running && !@services_busy}
        type="button"
        phx-click="boot_workspace"
        aria-label="Start workspace"
        class="focus-ring inline-flex items-center gap-1.5 rounded-md px-3 min-h-9 md:min-h-8 text-xs font-medium bg-violet-600 hover:bg-violet-700 active:bg-violet-800 text-white transition-colors"
      >
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="currentColor" class="w-3 h-3" aria-hidden="true">
          <path d="M4.5 3.5v9l7-4.5-7-4.5Z" />
        </svg>
        Start
      </button>
    </div>
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
