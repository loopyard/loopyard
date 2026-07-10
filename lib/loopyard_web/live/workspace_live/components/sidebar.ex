defmodule LoopyardWeb.Live.WorkspaceLive.Components.Sidebar do
  @moduledoc "Sidebar components for workspace_live: sidebar, service_item, volume_item, agent_list_item, new_agent_screen."
  use Phoenix.Component

  import LoopyardWeb.Components.Sidebar,
    only: [
      status_dot: 1,
      agent_display_status: 1,
      service_dot: 1,
      service_detail: 1,
      first_host_port: 1,
      thinking_word: 2
    ]

  import LoopyardWeb.Components.SideNav, only: [section: 1, row: 1, empty: 1]
  import LoopyardWeb.Live.WorkspaceLive.Components.ContextPanel, only: [context_sections: 1]

  import LoopyardWeb.Live.WorkspaceLive.Components.Formatters,
    only: [
      service_status_text: 1,
      exit_reason: 1,
      derive_volume_description: 1
    ]

  # Always show sync for Local workspaces — even nil means "initializing"
  defp sync_relevant?(_), do: true

  # Container-related sync errors are "waiting" states, not real errors
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
    base_path =
      if assigns.project do
        "/projects/#{assigns.project.id}/workspaces/#{assigns.workspace_entry.id}"
      else
        "/projects/#{assigns.workspace_id}/workspaces/#{assigns.workspace_id}"
      end

    assigns = assign(assigns, :base_path, base_path)

    ~H"""
    <%!-- The workspace rail (RIGHT side): Agents/Services/Volumes nav + the
         selected agent's context. On mobile: full-width when visible
         (index/context), hidden when an agent/service is selected. On md+:
         always visible as a fixed-width rail. --%>
    <aside class={[
      "flex-none border-l border-zinc-200 dark:border-zinc-700/80 flex flex-col bg-zinc-50 dark:bg-zinc-900/50",
      "w-full md:w-80",
      if(
        @live_action in [
          :new,
          :chat,
          :container,
          :context_panel,
          :service,
          :console,
          :services,
          :volume,
          :volume_files_root,
          :volume_file,
          :volume_git,
          :sync
        ] || @selected_id || @selected_service,
        do: "hidden md:flex",
        else: "flex"
      )
    ]}>
      <div class="flex-1 overflow-y-auto">
        <.section label="Agents">
          <.agent_list_item
            :for={agent <- @agents}
            agent={agent}
            selected={@selected_id == agent.id}
            editing={Map.get(assigns, :editing_agent_id) == agent.id}
          />
          <.empty :if={@agents == []} text="No agents" />
          <.row
            patch={"#{@base_path}/new"}
            class="text-violet-600 dark:text-violet-400 hover:bg-violet-50 dark:hover:bg-violet-500/10"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 16 16"
              fill="currentColor"
              class="w-3.5 h-3.5 flex-none"
              aria-hidden="true"
            >
              <path d="M8.75 3.75a.75.75 0 0 0-1.5 0v3.5h-3.5a.75.75 0 0 0 0 1.5h3.5v3.5a.75.75 0 0 0 1.5 0v-3.5h3.5a.75.75 0 0 0 0-1.5h-3.5v-3.5Z" />
            </svg>
            <span>New agent</span>
          </.row>
        </.section>

        <.section :if={@service_statuses != [] || !@services_loaded} label="Services">
          <.service_item
            :for={svc <- @service_statuses}
            svc={svc}
            base_path={@base_path}
            selected={@selected_service == svc.name}
            host={@host}
            workspace_id={@workspace_id}
          />
          <.empty :if={!@services_loaded} text="Loading..." />
        </.section>

        <%!-- Volumes + Host file sync live in one group. Sync is
             conceptually a volume data-source, and shoving it into its
             own labeled section created an orphan row with ~40px of
             dead space above it. --%>
        <.section label="Volumes">
          <.volume_item :for={vol <- @volumes} vol={vol} base_path={@base_path} />
          <.empty :if={!@volumes_loaded} text="Loading..." />
          <.empty :if={@volumes_loaded && @volumes == []} text="No volumes" />
          <.row
            :if={@is_local_source? && sync_relevant?(@sync_status)}
            patch={"#{@base_path}/sync"}
            aria_label="Open host file sync status"
          >
            <span
              class={"w-1.5 h-1.5 rounded-full flex-none #{sync_dot(@sync_status)}"}
              aria-hidden="true"
            ></span>
            <span class="truncate text-zinc-600 dark:text-zinc-400">Host file sync</span>
          </.row>
        </.section>

        <%!-- The selected agent's context (model, tokens, cost, docker, tools)
             folds in below the workspace nav — one combined rail. --%>
        <.context_sections
          :if={@selected_agent}
          agent={@selected_agent}
          changes={@changes}
          editing_name={@editing_name}
        />
      </div>
    </aside>
    """
  end

  # --- Workspace switcher (LEFT rail / "super-task-bar") ---

  # Where clicking a workspace lands you, in priority order:
  #   1. resume_path — this window's last view there (per-connection tracked),
  #   2. its latest agent's chat, else
  #   3. the workspace root (which spawns a working agent, D10).
  defp ws_switch_target(project_id, ws) do
    base = "/projects/#{project_id}/workspaces/#{ws.id}"

    cond do
      ws[:resume_path] -> ws.resume_path
      ws[:latest_agent_id] -> "#{base}/agents/#{ws.latest_agent_id}"
      true -> base
    end
  end

  @doc """
  The left rail: switch between the workspaces (branches) of this project.
  Each row navigates to that workspace; a status dot reflects whether its
  cluster is running. A "New workspace" link goes to the project's
  new-workspace screen. Desktop-only (lg+); mobile switches via the project
  page.
  """
  attr :workspaces, :list, default: []
  attr :current_id, :string, required: true
  attr :project, :map, required: true

  def workspace_switcher(assigns) do
    ~H"""
    <aside class="hidden lg:flex flex-none w-56 border-r border-zinc-200 dark:border-zinc-700/80 flex-col bg-zinc-50 dark:bg-zinc-900/50">
      <div class="flex-1 overflow-y-auto">
        <.section label="Workspaces">
          <.link
            :for={ws <- @workspaces}
            navigate={ws_switch_target(@project.id, ws)}
            class={[
              "flex items-center gap-2 px-3 min-h-9 text-sm transition-colors",
              if(ws.id == @current_id,
                do:
                  "bg-violet-50 dark:bg-violet-500/10 text-violet-700 dark:text-violet-300 font-medium",
                else: "text-zinc-600 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800/60"
              )
            ]}
            aria-current={ws.id == @current_id && "page"}
          >
            <span class={"w-1.5 h-1.5 rounded-full flex-none #{if ws.status == :running, do: "bg-emerald-500", else: "bg-zinc-400"}"}></span>
            <span class="truncate flex-1">{ws.name}</span>
            <span
              :if={ws[:is_main]}
              class="text-[9px] uppercase tracking-wider text-zinc-400 dark:text-zinc-500 flex-none"
            >
              default
            </span>
          </.link>
          <.empty :if={@workspaces == []} text="No workspaces" />
          <.row
            navigate={"/projects/#{@project.id}/new"}
            class="text-violet-600 dark:text-violet-400 hover:bg-violet-50 dark:hover:bg-violet-500/10"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 16 16"
              fill="currentColor"
              class="w-3.5 h-3.5 flex-none"
              aria-hidden="true"
            >
              <path d="M8.75 3.75a.75.75 0 0 0-1.5 0v3.5h-3.5a.75.75 0 0 0 0 1.5h3.5v3.5a.75.75 0 0 0 1.5 0v-3.5h3.5a.75.75 0 0 0 0-1.5h-3.5v-3.5Z" />
            </svg>
            <span>New workspace</span>
          </.row>
        </.section>
      </div>
    </aside>
    """
  end

  # Primary sidebar header: workspace state + Start/Stop. Driven by
  # the single :workspace_state atom (:stopped | :starting | :started
  # | :stopping), validated through Loopyard.Cluster.StateMachine.
  # :workspace_state_since carries the transition timestamp so the
  # header can show "Starting… 12s" during in-flight transitions.
  # --- New Agent Screen ---

  def new_agent_screen(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto p-6 md:p-8">
      <div class="max-w-2xl mx-auto">
        <h2 class="text-xl font-semibold text-zinc-900 dark:text-zinc-100 mb-1">New Agent</h2>
        <p class="text-base text-zinc-500 dark:text-zinc-400 mb-4">
          Start an agent with a task, or pick a preset below.
        </p>

        <form id="new-agent-form" phx-submit="spawn_agent_with_message" class="space-y-4">
          <textarea
            name="message"
            id="new-agent-input"
            rows="3"
            placeholder="What should this agent work on? (leave blank to start empty)"
            class="w-full rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-4 py-3 text-base
                   text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 resize-none
                   focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400"
          ></textarea>
          <button
            type="submit"
            class="rounded-lg bg-zinc-900 dark:bg-zinc-100 px-5 py-2.5 text-base font-medium text-white dark:text-zinc-900
                   hover:bg-zinc-700 dark:hover:bg-zinc-300 transition-colors"
          >
            Launch Agent
          </button>
        </form>

        <div class="mt-6 pt-6 border-t border-zinc-200 dark:border-zinc-700/80">
          <div class="text-xs uppercase tracking-wider text-zinc-500 dark:text-zinc-400 font-semibold mb-3">
            Presets
          </div>
          <div class="space-y-2">
            <button
              phx-click="spawn_agent_with_message"
              phx-value-preset="setup"
              class="w-full text-left rounded-lg border border-zinc-200 dark:border-zinc-700 px-4 py-3 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors"
            >
              <div class="text-base font-medium text-zinc-900 dark:text-zinc-100">
                Set up dev environment
              </div>
              <div class="text-xs text-zinc-500 dark:text-zinc-400 mt-0.5">
                Write Dockerfile + docker-compose.yml, start services, install deps.
              </div>
            </button>
            <button
              phx-click="spawn_agent_with_message"
              phx-value-preset="debug"
              class="w-full text-left rounded-lg border border-zinc-200 dark:border-zinc-700 px-4 py-3 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors"
            >
              <div class="text-base font-medium text-zinc-900 dark:text-zinc-100">
                Debug failing services
              </div>
              <div class="text-xs text-zinc-500 dark:text-zinc-400 mt-0.5">
                Check service logs, diagnose errors, fix configuration.
              </div>
            </button>
            <button
              phx-click="spawn_agent_with_message"
              phx-value-preset="explore"
              class="w-full text-left rounded-lg border border-zinc-200 dark:border-zinc-700 px-4 py-3 hover:bg-zinc-50 dark:hover:bg-zinc-800/50 transition-colors"
            >
              <div class="text-base font-medium text-zinc-900 dark:text-zinc-100">
                Explore the codebase
              </div>
              <div class="text-xs text-zinc-500 dark:text-zinc-400 mt-0.5">
                Read files, search code, understand the project structure.
              </div>
            </button>
          </div>
        </div>

        <div class="mt-6">
          <.link
            patch={@base_path}
            class="text-base text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300 transition-colors"
          >
            Cancel
          </.link>
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
    <.row
      id={"service-row-#{@svc.name}"}
      as={:div}
      selected={@selected}
      class="grid grid-cols-[1fr_auto]"
    >
      <.link
        patch={"#{@base_path}/services/#{@svc.name}"}
        class="focus-ring flex items-center gap-2 min-w-0 -mx-2 px-2 h-full rounded"
        aria-label={"Open #{@svc.name} service"}
      >
        <span class={"w-1.5 h-1.5 rounded-full flex-none #{service_dot(@svc)}"} aria-hidden="true"></span>
        <span class="truncate text-zinc-600 dark:text-zinc-400">{@svc.name}</span>
      </.link>
      <div class="flex items-center justify-end gap-1.5">
        <%!-- Open port: green pill with port number (link opens URL).
             Closed port: plain link + Open Port button.
             Close Port lives on the service detail page, not here. --%>
        <%= if @first_port && @svc.status == :running && Map.get(@svc, :exposed) do %>
          <a
            href={"http://#{@host}:#{@first_port}"}
            target="_blank"
            rel="noopener noreferrer"
            aria-label={"Open http://#{@host}:#{@first_port}"}
            class="focus-ring inline-flex items-center min-h-8 md:min-h-6 px-2 rounded text-xs font-mono font-medium bg-emerald-500/15 text-emerald-600 dark:text-emerald-400 hover:bg-emerald-500/25 transition-colors"
          >
            :{@first_port}
          </a>
        <% else %>
          <.share_button
            :if={@first_port && Map.get(@svc, :container_port) && @svc.status == :running}
            svc={@svc}
          />
        <% end %>
        <span
          :if={!@first_port && service_status_text(@svc)}
          class="text-xs text-blue-500 dark:text-blue-400"
        >
          {service_status_text(@svc)}
        </span>
        <span
          :if={!@first_port && !service_status_text(@svc) && @svc.status == :running}
          class="text-xs text-zinc-500 dark:text-zinc-400 font-mono truncate max-w-[88px]"
        >
          {service_detail(@svc)}
        </span>
        <span
          :if={@svc.status == :crashed && @svc.exit_info}
          class="text-xs text-red-500 truncate max-w-[88px]"
        >
          {exit_reason(@svc.exit_info)}
        </span>
      </div>
    </.row>
    """
  end

  # Open Port button — switches the proxy bind address.
  attr :svc, :map, required: true

  defp share_button(assigns) do
    exposed? = Map.get(assigns.svc, :exposed, false)
    assigns = assign(assigns, :exposed?, exposed?)

    ~H"""
    <button
      type="button"
      phx-click="toggle_port_exposure"
      phx-value-service={@svc.name}
      phx-value-container_port={Map.get(@svc, :container_port)}
      phx-value-expose={to_string(!@exposed?)}
      aria-label={
        if @exposed?,
          do: "Close port — restrict to this machine",
          else: "Open port — share on network"
      }
      class={[
        "focus-ring inline-flex items-center min-h-8 md:min-h-6 px-1.5 rounded text-[10px] font-medium transition-colors",
        if(@exposed?,
          do: "bg-emerald-500/15 text-emerald-600 dark:text-emerald-400 hover:bg-emerald-500/25",
          else: "text-zinc-500 dark:text-zinc-400 hover:bg-zinc-200 dark:hover:bg-zinc-700"
        )
      ]}
    >
      {if @exposed?, do: "Close Port", else: "Open Port"}
    </button>
    """
  end

  def volume_item(assigns) do
    # Use description from volume_info if available, otherwise derive from name
    description = assigns.vol[:description] || derive_volume_description(assigns.vol.name)
    service = assigns.vol[:service]

    assigns =
      assigns
      |> assign(:description, description)
      |> assign(:service, service)

    ~H"""
    <.row
      id={"volume-row-#{@vol.name}"}
      patch={"#{@base_path}/volumes/#{@vol.name}"}
      aria_label={"Open #{@description} volume"}
    >
      <span class="w-1.5 h-1.5 rounded-full flex-none bg-blue-400" aria-hidden="true"></span>
      <span class="truncate text-zinc-600 dark:text-zinc-400 flex-1">{@description}</span>
      <span :if={@service && @service != "workspace"} class="text-xs text-zinc-500 flex-none">
        {@service}
      </span>
      <span :if={@vol[:size]} class="text-xs text-zinc-500 dark:text-zinc-400 font-mono flex-none">
        {@vol.size}
      </span>
    </.row>
    """
  end

  def agent_list_item(assigns) do
    display = agent_display_status(assigns.agent)
    editing = Map.get(assigns, :editing, false)
    assigns = assign(assigns, display: display, editing: editing)

    ~H"""
    <div :if={@display != :hidden} id={"agent-row-#{@agent.id}"} class="flex items-stretch gap-1">
      <%!-- Inline rename form --%>
      <form
        :if={@editing}
        phx-submit="rename_agent"
        phx-click-away="cancel_rename_sidebar"
        phx-value-id={@agent.id}
        class="flex-1 flex items-center gap-1 px-2 py-1"
      >
        <span class={"w-1.5 h-1.5 rounded-full flex-none #{status_dot(@display)}"} aria-hidden="true"></span>
        <input
          type="text"
          name="name"
          value={@agent.name}
          autofocus
          class="flex-1 min-w-0 rounded border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-2 py-0.5 text-sm
                 text-zinc-900 dark:text-zinc-100 focus:outline-none focus:ring-1 focus:ring-violet-500/30"
        />
      </form>
      <%!-- Normal display --%>
      <.row
        :if={!@editing}
        phx_click="select_agent"
        phx_value={%{id: @agent.id}}
        selected={@selected}
        aria_label={"Open agent #{@agent.name} (#{@display})"}
        class="flex-1"
      >
        <span class={"w-1.5 h-1.5 rounded-full flex-none #{status_dot(@display)}"} aria-hidden="true"></span>
        <span
          class="truncate text-zinc-600 dark:text-zinc-400"
          phx-dblclick="start_rename_sidebar"
          phx-value-id={@agent.id}
        >
          {@agent.name}
        </span>
        <span
          :if={@display == :thinking}
          class="text-xs text-violet-500 dark:text-violet-400 flex-none"
        >
          {@agent[:thinking_word] || thinking_word(@agent.id, @agent[:active_tool])}
        </span>
        <span :if={@display == :crashed} class="text-xs text-red-500 dark:text-red-400 flex-none">
          Crashed
        </span>
      </.row>
      <button
        :if={!@editing && @display in [:sleeping, :crashed]}
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
