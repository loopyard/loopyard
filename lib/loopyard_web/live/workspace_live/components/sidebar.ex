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

  import LoopyardWeb.Components.SideNav, only: [section: 1, row: 1]
  import LoopyardWeb.Live.WorkspaceLive.Components.ContextPanel, only: [context_sections: 1]

  import LoopyardWeb.Live.WorkspaceLive.Components.DetailContexts,
    only: [service_context: 1, volume_context: 1]

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
      "flex-none border-l border-zinc-200 dark:border-zinc-700/80 flex flex-col bg-brand-paper-shade dark:bg-brand-ink/50 safe-pr",
      "w-full md:w-80",
      if(
        @live_action in [
          :new,
          :chat,
          :container,
          :context_panel,
          :info,
          :service,
          :console,
          :services,
          :volume,
          :volume_files_root,
          :volume_file,
          :volume_git,
          :volume_history,
          :sync
        ] || @selected_id || @selected_service,
        do: "hidden md:flex",
        else: "flex"
      )
    ]}>
      <%!-- ── L1 ZONE A · SWITCHER ──────────────────────────────────────────
           The workspace's resources — agents / services / volumes — you pick
           one and its detail fills the zone below. Fixed-ish height (caps at
           ~45% then scrolls internally) on a faintly tinted surface, closed by
           the ONE heavy rule in the pane. This is the "what's in this
           workspace" nav, distinct from "the thing you selected". --%>
      <div class="flex-1 min-h-0 overflow-y-auto bg-zinc-100 dark:bg-zinc-800/40 border-b-2 border-zinc-200 dark:border-zinc-700/70">
        <.workspace_switcher
          agents={@agents}
          service_statuses={@service_statuses}
          volumes={@volumes}
          changes={@changes}
          selected_id={@selected_id}
          selected_service={@selected_service}
          selected_volume={Map.get(assigns, :selected_volume)}
          live_action={@live_action}
          editing_agent_id={Map.get(assigns, :editing_agent_id)}
          base_path={@base_path}
          host={@host}
          workspace_id={@workspace_id}
          is_local_source?={@is_local_source?}
          sync_status={@sync_status}
        />
      </div>

      <%!-- ── L1 ZONE B · DETAIL ─────────────────────────────────────────────
           The SELECTED item's detail — polymorphic by kind so the IA is
           identical whatever you picked: an agent, a service, or a volume each
           render the SAME 3-zone shape (sticky `detail_hero` + scrolling sections
           + sticky `action_bar` of buttons). This is the ONE place all the
           buttons + LiveView status for the selected thing live, instead of being
           scattered into the center pane's top toolbar. Driven by `live_action`
           (unambiguous) rather than which "selected_*" happens to be set. --%>
      <%!-- Detail is ANCHORED TO THE BOTTOM at content height, capped at 50% of
           the rail (the nav above takes the rest via flex-1). Content-height
           (not flex-1) so a short/detail-less panel doesn't stretch and leave
           the sticky footer floating mid-rail — hero + footer stay compact and
           pinned to the bottom. Caps at 50% then scrolls internally. --%>
      <div
        :if={detail_kind(@live_action, @selected_agent) != nil}
        id="rail-detail-scroll"
        phx-hook="StickyEdge"
        class="flex-none md:max-h-[50%] overflow-y-auto"
      >
        <.context_sections
          :if={detail_kind(@live_action, @selected_agent) == :agent}
          agent={@selected_agent}
          changes={@changes}
          editing_name={@editing_name}
          base_path={@base_path}
          live_token_est={Map.get(assigns, :live_token_est, 0)}
        />
        <.service_context
          :if={detail_kind(@live_action, @selected_agent) == :service}
          svc={Enum.find(@service_statuses, &(&1.name == @selected_service))}
          service_name={@selected_service}
          base_path={@base_path}
          host={@host}
        />
        <.volume_context
          :if={detail_kind(@live_action, @selected_agent) == :volume}
          vol={Enum.find(@volumes, &(&1.name == @selected_volume))}
          volume_name={@selected_volume}
          base_path={@base_path}
          changes={@changes}
        />
      </div>
    </aside>
    """
  end

  # Which detail panel Zone B shows. Service + volume routes win over a
  # lingering selected_agent so opening a service from an agent chat swaps the
  # detail to that service. Agent is the fallback whenever one is selected.
  defp detail_kind(action, _selected_agent)
       when action in [:service, :console],
       do: :service

  defp detail_kind(action, _selected_agent)
       when action in [
              :volume,
              :volume_files_root,
              :volume_file,
              :volume_git,
              :volume_history,
              :git_diff,
              :git_staged_diff,
              :git_commit,
              :git_commit_file
            ],
       do: :volume

  defp detail_kind(_action, selected_agent) when not is_nil(selected_agent), do: :agent
  defp detail_kind(_action, _selected_agent), do: nil

  # The workspace resource switcher — Agents / Services / Volumes, grouped and
  # tight. Shared verbatim by the desktop rail (Zone A of `sidebar/1`) and the
  # mobile "Workspace" tab, so the two never drift. A group's header shows only
  # when it has contents; a lone item just sits under its header.
  attr :agents, :list, required: true
  attr :service_statuses, :list, default: []
  attr :volumes, :list, default: []
  attr :changes, :map, default: %{staged: [], unstaged: []}
  attr :selected_id, :string, default: nil
  attr :selected_service, :string, default: nil
  attr :selected_volume, :string, default: nil
  attr :live_action, :atom, default: :index
  attr :editing_agent_id, :string, default: nil
  attr :base_path, :string, required: true
  attr :host, :string, default: nil
  attr :workspace_id, :string, required: true
  attr :is_local_source?, :boolean, default: false
  attr :sync_status, :any, default: nil

  def workspace_switcher(assigns) do
    assigns =
      assigns
      |> assign(:changes_count, changes_count(assigns.changes))
      # The +/- line stat (added/removed) for the Changes row — pulled from the
      # ChangeCounts cache, the same source the (now-removed) left-rail git-stat
      # used. This is where the diff belongs: next to Changes, not in the nav rail.
      |> assign(:changes_stat, Loopyard.ChangeCounts.get(assigns.workspace_id))

    ~H"""
    <.section>
      <%!-- Agents header ALWAYS shows (even with zero agents) because it now
           carries the + affordance to add one — the old standalone "New agent"
           row is gone; the + in the header replaces it. --%>
      <.group_label text="Agents">
        <:action>
          <.link
            patch={"#{@base_path}/new"}
            aria-label="New agent"
            class="focus-ring inline-flex items-center justify-center w-7 h-7 rounded-md text-indigo-600 dark:text-indigo-400 hover:bg-indigo-50 dark:hover:bg-indigo-500/10 transition-colors"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              viewBox="0 0 16 16"
              fill="currentColor"
              class="w-4 h-4"
              aria-hidden="true"
            >
              <path d="M8.75 3.75a.75.75 0 0 0-1.5 0v3.5h-3.5a.75.75 0 0 0 0 1.5h3.5v3.5a.75.75 0 0 0 1.5 0v-3.5h3.5a.75.75 0 0 0 0-1.5h-3.5v-3.5Z" />
            </svg>
          </.link>
        </:action>
      </.group_label>
      <.agent_list_item
        :for={agent <- @agents}
        agent={agent}
        selected={@selected_id == agent.id}
        editing={@editing_agent_id == agent.id}
      />

      <.group_label :if={@service_statuses != []} text="Services" />
      <.service_item
        :for={svc <- @service_statuses}
        svc={svc}
        base_path={@base_path}
        selected={@selected_service == svc.name}
        host={@host}
        workspace_id={@workspace_id}
      />

      <.group_label
        :if={@volumes != [] || (@is_local_source? && sync_relevant?(@sync_status))}
        text="Files"
      />
      <.volume_items
        :for={vol <- @volumes}
        vol={vol}
        base_path={@base_path}
        changes_count={@changes_count}
        changes_stat={@changes_stat}
        live_action={@live_action}
        selected_volume={@selected_volume}
      />
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
            aria-label="What should this agent work on?"
            class="w-full rounded-lg border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-4 py-3 text-base
                   text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 resize-none
                   focus:outline-none focus:ring-2 focus:ring-indigo-500/20 focus:border-indigo-400"
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
          <div class="text-sm uppercase tracking-wider text-zinc-500 dark:text-zinc-400 font-semibold mb-3">
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
              <div class="text-sm text-zinc-500 dark:text-zinc-400 mt-0.5">
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
              <div class="text-sm text-zinc-500 dark:text-zinc-400 mt-0.5">
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
              <div class="text-sm text-zinc-500 dark:text-zinc-400 mt-0.5">
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

  # A group header inside the workspace switcher — Agents / Services / Volumes.
  # Tight (small top gap) so the groups don't sprawl like three separate
  # sections did, but readable enough to scan.
  attr :text, :string, required: true
  slot :action, doc: "optional right-aligned control in the header (e.g. a + button)"

  def group_label(assigns) do
    ~H"""
    <%!-- pt-4 = the ONE between-groups gap, shared with SideNav.section (the
         details rail) — the two zones of the right rail must breathe at the
         same rhythm or the seam between them reads as two different UIs. --%>
    <div class="flex items-center justify-between gap-2 px-2 pt-4 pb-1 first:pt-1.5">
      <span class="text-sm md:text-xs font-semibold uppercase tracking-wider text-zinc-500 dark:text-zinc-400">
        {@text}
      </span>
      <div :if={@action != []} class="flex-none -my-1">{render_slot(@action)}</div>
    </div>
    """
  end

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
            class="focus-ring inline-flex items-center min-h-8 md:min-h-6 px-2 rounded text-sm font-mono font-medium bg-emerald-500/15 text-emerald-600 dark:text-emerald-400 hover:bg-emerald-500/25 transition-colors"
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
          class="text-sm text-blue-500 dark:text-blue-400"
        >
          {service_status_text(@svc)}
        </span>
        <span
          :if={!@first_port && !service_status_text(@svc) && @svc.status == :running}
          class="text-sm text-zinc-500 dark:text-zinc-400 font-mono truncate max-w-[88px]"
        >
          {service_detail(@svc)}
        </span>
        <span
          :if={@svc.status == :crashed && @svc.exit_info}
          class="text-sm text-red-500 truncate max-w-[88px]"
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
        "focus-ring inline-flex items-center min-h-8 md:min-h-6 px-1.5 rounded text-xs font-medium transition-colors",
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

  # One volume's switcher rows. The CODE volume is the standard-switcher way in:
  # Files / Changes / History are each their OWN row (no tab bar inside the
  # detail view). Other volumes (pgdata, caches) get a single row into their
  # file browser. Info for any volume lives in the detail rail / mobile sheet.
  attr :vol, :map, required: true
  attr :base_path, :string, required: true
  attr :changes_count, :integer, default: 0
  attr :changes_stat, :map, default: nil
  attr :live_action, :atom, default: :index
  attr :selected_volume, :string, default: nil

  def volume_items(assigns) do
    description = assigns.vol[:description] || derive_volume_description(assigns.vol.name)
    code? = String.contains?(assigns.vol.name || "", "code")
    mine? = assigns.selected_volume == assigns.vol.name

    assigns =
      assigns
      |> assign(:description, description)
      |> assign(:code?, code?)
      |> assign(
        :files_selected,
        mine? && assigns.live_action in [:volume, :volume_files_root, :volume_file]
      )
      |> assign(
        :changes_selected,
        mine? && assigns.live_action in [:volume_git, :git_diff, :git_staged_diff]
      )
      |> assign(
        :history_selected,
        mine? && assigns.live_action in [:volume_history, :git_commit, :git_commit_file]
      )

    ~H"""
    <%= if @code? do %>
      <.row
        id={"volume-row-#{@vol.name}-files"}
        patch={"#{@base_path}/volumes/#{@vol.name}/files"}
        selected={@files_selected}
        aria_label="Browse project files"
      >
        <span class="w-1.5 h-1.5 rounded-full flex-none bg-blue-400" aria-hidden="true"></span>
        <span class="truncate text-zinc-600 dark:text-zinc-400 flex-1">Files</span>
        <span :if={@vol[:size]} class="text-sm text-zinc-500 dark:text-zinc-400 font-mono flex-none">
          {@vol.size}
        </span>
      </.row>
      <.row
        id={"volume-row-#{@vol.name}-changes"}
        patch={"#{@base_path}/volumes/#{@vol.name}/git"}
        selected={@changes_selected}
        aria_label="View working-tree changes"
      >
        <span class="w-1.5 h-1.5 rounded-full flex-none bg-amber-400" aria-hidden="true"></span>
        <span class="truncate text-zinc-600 dark:text-zinc-400 flex-1">Changes</span>
        <%!-- The useful diff stat lives HERE (right sidebar), not in the nav rail:
             the +/- line count when we have it, with the changed-file count as a
             quiet secondary. --%>
        <span
          :if={@changes_stat && (@changes_stat.added > 0 || @changes_stat.removed > 0)}
          class="flex-none inline-flex items-center gap-1.5 text-sm font-mono font-medium"
          title={"+#{@changes_stat.added} / -#{@changes_stat.removed} lines across #{@changes_count} file(s)"}
        >
          <span class="text-emerald-600 dark:text-emerald-400">+{@changes_stat.added}</span>
          <span class="text-red-500 dark:text-red-400">−{@changes_stat.removed}</span>
        </span>
        <span
          :if={
            (is_nil(@changes_stat) || (@changes_stat.added == 0 && @changes_stat.removed == 0)) &&
              @changes_count > 0
          }
          class="flex-none inline-flex items-center rounded px-1.5 text-sm font-mono font-medium bg-amber-500/15 text-amber-600 dark:text-amber-400"
          title={"#{@changes_count} changed file(s)"}
        >
          ±{@changes_count}
        </span>
      </.row>
      <.row
        id={"volume-row-#{@vol.name}-history"}
        patch={"#{@base_path}/volumes/#{@vol.name}/history"}
        selected={@history_selected}
        aria_label="View commit history"
      >
        <span class="w-1.5 h-1.5 rounded-full flex-none bg-zinc-400" aria-hidden="true"></span>
        <span class="truncate text-zinc-600 dark:text-zinc-400 flex-1">History</span>
      </.row>
    <% else %>
      <.row
        id={"volume-row-#{@vol.name}"}
        patch={"#{@base_path}/volumes/#{@vol.name}/files"}
        selected={@files_selected}
        aria_label={"Open #{@description} files"}
      >
        <span class="w-1.5 h-1.5 rounded-full flex-none bg-blue-400" aria-hidden="true"></span>
        <span class="truncate text-zinc-600 dark:text-zinc-400 flex-1">{@description}</span>
        <span :if={@vol[:size]} class="text-sm text-zinc-500 dark:text-zinc-400 font-mono flex-none">
          {@vol.size}
        </span>
      </.row>
    <% end %>
    """
  end

  # Changed-file count for a working tree (staged + unstaged, deduped by path).
  defp changes_count(%{} = changes) do
    ((Map.get(changes, :staged) || []) ++ (Map.get(changes, :unstaged) || []))
    |> Enum.uniq_by(& &1.path)
    |> length()
  end

  defp changes_count(_), do: 0

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
          aria-label="Agent name"
          autofocus
          class="flex-1 min-w-0 rounded border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-2 py-0.5 text-sm
                 text-zinc-900 dark:text-zinc-100 focus:outline-none focus:ring-1 focus:ring-indigo-500/30"
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
          class="flex-1 min-w-0 truncate text-zinc-600 dark:text-zinc-400"
          phx-dblclick="start_rename_sidebar"
          phx-value-id={@agent.id}
        >
          {@agent.name}
        </span>
        <%!-- Rough additional status, RIGHT-aligned: dot + name on the left, what
             it's doing on the right. --%>
        <span
          :if={@display == :thinking}
          class="text-sm text-indigo-500 dark:text-indigo-400 flex-none truncate max-w-[9rem]"
        >
          {@agent[:thinking_word] || thinking_word(@agent.id, @agent[:active_tool])}
        </span>
        <span :if={@display == :crashed} class="text-sm text-red-500 dark:text-red-400 flex-none">
          Crashed
        </span>
      </.row>
      <%!-- No inline destroy control. The row is a single target: click to open
           the agent, and remove/destroy lives in its detail view. Keeps the list
           calm (no controls appearing as agents boot) and makes destruction a
           deliberate, one-place action. --%>
    </div>
    """
  end
end
