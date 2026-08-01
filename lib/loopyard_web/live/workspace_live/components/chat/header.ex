defmodule LoopyardWeb.Live.WorkspaceLive.Components.Chat.Header do
  @moduledoc """
  The chat header component group — the mobile workspace header
  (`chat_header/1`), the desktop agent header (`agent_header/1`), and the
  detail-level segmented control. Split out of
  `LoopyardWeb.Live.WorkspaceLive.Components.Chat` to keep that file under
  its size cap; Chat re-exposes the public components via `defdelegate`.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias LoopyardWeb.Components.Nav

  import LoopyardWeb.Components.Common, only: [dot: 1, control_btn: 1, operator_link: 1]
  import LoopyardWeb.Components.Sidebar, only: [status_dot: 1, agent_display_status: 1]
  import LoopyardWeb.Live.WorkspaceLive.Components.Formatters, only: [time_ago: 1]

  # Section-switcher model (categories / items / hrefs) — split out for the
  # module-size invariant. Chat renders; ChatNav decides what to render.
  import LoopyardWeb.Live.WorkspaceLive.Components.ChatNav,
    only: [
      section_title: 1,
      section_tabs: 1,
      active_category: 1,
      category_href: 2,
      category_items: 1,
      current_item: 1,
      current_ws_port: 2
    ]

  # Build the breadcrumb trail for this workspace view.
  #  Loopyard / {project.name} / {workspace label}
  #
  # The trailing crumb is whatever the workspace's Source adapter
  # decides — branch name for Local, eventually `owner/repo#branch`
  # for GitHub. The label is owned by the adapter so the UI never
  # invents one. It links to the workspace overview (`base_path`) on
  # every sub-route so users can jump back from agents / services /
  # volumes. On the overview itself (`live_action == :index`) the
  # path is `nil`, which the Breadcrumbs component renders as the
  # current page (no link, aria-current="page").
  # The ONE state derivation (Common.workspace_state), read from the same tree
  # the rails render — so the dot in this header can't disagree with the dot in
  # the sidebar for the same workspace.
  defp ws_identity_state(tree, ws_id) do
    entry =
      Enum.find_value(tree || [], fn p ->
        Enum.find(p.workspaces || [], &(&1.id == ws_id))
      end)

    LoopyardWeb.Components.Common.workspace_state(entry) || :asleep
  end

  def chat_header(assigns) do
    # The mobile workspace header (phone-only; desktop navigates from the rails).
    # Two rows that mirror the hierarchy Root → Project → Workspace →
    # { Agents · Services · Repo }:
    #
    #  Row 1  ←  Loopyard / uncringe .................... 🔊  (WHERE you are)
    #  Row 2  [ Agents · Services · Repo ]  ● my-agent · Ready  Switch ⌄  (WHAT)
    #
    # Row 1 is the location breadcrumb (project / workspace) + back-out + sound.
    # Row 2 switches CATEGORY (content-first: jump to your last item there) and
    # names the current ITEM; tapping the item zooms OUT to a switcher of the
    # other items in that category — pick one to zoom back in.
    # Set :active first, on its own, so the item/current helpers below (which
    # match on :active) see it — inside a single pipe, `assigns` in each arg
    # still refers to the pre-pipe value.
    assigns = assign(assigns, :active, active_category(assigns.live_action))

    assigns =
      assigns
      |> assign(:agents_href, category_href(:agents, assigns))
      |> assign(:services_href, category_href(:services, assigns))
      |> assign(:volumes_href, category_href(:volumes, assigns))
      |> assign(:items, category_items(assigns))
      |> assign(:current, current_item(assigns))
      |> assign(:details_sheet, details_sheet_for(assigns.active))
      |> assign(:ws_name, (assigns[:workspace_entry] || %{})[:name] || assigns.workspace.id)

    assigns =
      assigns
      |> assign(:section_tabs, section_tabs(assigns))
      |> assign(:project_items, project_items(assigns))
      |> assign(:workspace_items, workspace_items(assigns))

    assigns =
      assign(
        assigns,
        :can_switch,
        length(assigns.project_items) > 1 || length(assigns.workspace_items) > 1
      )

    # The workspace's primary reachable app port (exposed → has a URL), so the
    # phone header can offer a one-tap "open the running app" — otherwise ports
    # are buried in the Services tab on mobile.
    assigns =
      assign(assigns, :app_port, current_ws_port(assigns[:global_tree], assigns.workspace.id))

    ~H"""
    <%!-- Insets: the PAGE SHELL owns the top inset (never components — a
    second application here once doubled the top gap). --%>
    <div class="md:hidden">
      <%!-- Row 1: WHERE you are — back out + Project / Workspace + sound. Tapping
    either name throws open ONE full-screen switcher of every project and
    its workspaces (pick any to jump; ✕ / backdrop to bail). No pop-overs. --%>
      <%!-- Three zones, same model as desktop (see Breadcrumbs.trail/1): back
    button left, the CURRENT thing centred, actions right. Phones drop the
    logo and the ancestor crumbs entirely — a back button is the one
    affordance that fits, and the path is desktop chrome. A grid (not flex)
    so the centre is centred against the VIEWPORT, not against whatever the
    side zones happen to weigh; otherwise the title drifts as the actions
    change (a port chip appearing would shove it left). --%>
      <Nav.bar height="h-14" pad="px-2" gap="gap-1.5" class="relative">
        <Nav.back_button navigate="/workspaces" label="Back to workspaces" />
        <%!-- Absolutely centred against the BAR, not against the space left over
    between the back button and the actions. Flex centring drifts: the port
    chip appears only when a port is open, and the title would visibly shift
    when it does. max-w keeps it clear of both side zones on a narrow phone;
    pointer-events-none on the wrapper so the (invisible) full-width box
    can't swallow taps meant for the actions. --%>
        <nav
          class="absolute inset-x-0 flex justify-center pointer-events-none"
          aria-label="Location"
        >
          <%!-- The project / workspace PAIR is the current thing here, not the
    workspace alone: they're always shown together and the switcher moves
    between them as a unit, so splitting them across zones would break the
    thing the control acts on. A deliberate exception to "ancestors left,
    current centred". --%>
          <button
            :if={@can_switch}
            type="button"
            phx-click={Nav.toggle_panel("nav-switcher")}
            aria-controls="nav-switcher"
            aria-haspopup="dialog"
            aria-label={"Switch workspace — currently #{@project && @project.name} #{@ws_name}"}
            class="focus-ring pointer-events-auto max-w-[70%] min-w-0 inline-flex items-center gap-1 rounded-sm"
          >
            <LoopyardWeb.Components.Common.workspace_identity
              project={(@project && @project.name) || @ws_name}
              workspace={@project && @ws_name}
              state={ws_identity_state(@global_tree, @workspace.id)}
              class="min-w-0"
            />
            <Nav.chevron_down class="w-4 h-4 flex-none opacity-60 text-zinc-500 dark:text-zinc-400" />
          </button>
          <div :if={!@can_switch} class="pointer-events-auto max-w-[70%] min-w-0">
            <LoopyardWeb.Components.Common.workspace_identity
              project={(@project && @project.name) || @ws_name}
              workspace={@project && @ws_name}
              state={ws_identity_state(@global_tree, @workspace.id)}
              class="min-w-0"
            />
          </div>
        </nav>
        <:actions>
          <%!-- Details (agent/service/volume) moved to the section switcher row
    below — one consistent affordance, next to the thing it expands. --%>
          <%!-- One-tap open the running app: the workspace's exposed port URL,
    reachable from this phone (only shows when a port is network-open). --%>
          <.link
            :if={@app_port}
            href={@app_port.url}
            target="_blank"
            rel="noopener"
            aria-label={"Open app on port #{@app_port.port}"}
            class="focus-ring inline-flex items-center justify-center gap-0.5 h-11 px-2.5 rounded-sm font-mono text-sm text-emerald-600 dark:text-emerald-400 hover:bg-emerald-500/10 active:bg-emerald-500/20 transition-colors flex-none"
          >
            :{@app_port.port} <span class="text-xs opacity-70">↗</span>
          </.link>
          <.operator_link id="operator-workspace" />
        </:actions>
      </Nav.bar>

      <Nav.switcher_sheet :if={@can_switch} id="nav-switcher" title="Switch workspace">
        <:current>
          <%!-- The canonical identity component, same as the trigger it opens
    from and every rail in the app — so nothing changes shape when the
    sheet opens. --%>
          <LoopyardWeb.Components.Common.workspace_identity
            project={(@project && @project.name) || @ws_name}
            workspace={@project && @ws_name}
            state={ws_identity_state(@global_tree, @workspace.id)}
            class="min-w-0"
          />
        </:current>
        <LoopyardWeb.Components.ProjectList.project_groups
          projects={@global_tree}
          current_workspace_id={@workspace.id}
          row_click={JS.hide(to: "#nav-switcher")}
          size={:xs}
        />
      </Nav.switcher_sheet>

      <%!-- Row 2: WHAT you're looking at — section tabs + the current item, which
    taps open a full-screen switcher of siblings. --%>
      <Nav.section_switcher
        id="item-switcher"
        title={section_title(@active)}
        current={@current}
        items={@items}
        has_details={@details_sheet != nil}
        details_open={@mobile_detail_open}
      >
        <:tabs>
          <Nav.segmented items={@section_tabs} label="Workspace section" />
        </:tabs>
        <:extra>
          <.link
            :if={@active == :agents}
            patch={"#{@base_path}/new"}
            phx-click={JS.hide(to: "#item-switcher")}
            class="flex items-center gap-2 px-3 min-h-[2.75rem] rounded-sm text-sm font-medium text-violet-600 dark:text-violet-400 active:bg-violet-50 dark:active:bg-violet-500/10"
          >
            + New agent
          </.link>
        </:extra>
      </Nav.section_switcher>
    </div>
    """
  end

  # All projects, for the project crumb switcher (tap the project name). Sourced
  # from the same @global_tree the left rail uses, so it's already in the socket.
  # The bottom-sheet id whose "details" the switcher's details button expands,
  # per active section. Each has a matching bottom_sheet in workspace_live's
  # render — the ONE consistent detail affordance for agents / services / files.
  defp details_sheet_for(:agents), do: "agent-context"
  defp details_sheet_for(:services), do: "service-context"
  defp details_sheet_for(:volumes), do: "volume-context"
  defp details_sheet_for(_), do: nil

  defp project_items(%{global_tree: tree, project: project}) when is_list(tree) do
    Enum.map(tree, fn p ->
      %{label: p.name, href: "/projects/#{p.id}", active?: project && p.id == project.id}
    end)
  end

  defp project_items(_), do: []

  # Sibling workspaces within the current project, for the workspace crumb
  # switcher (tap the workspace name). Empty (→ plain text, no switcher) when the
  # project has only this one.
  defp workspace_items(%{global_tree: tree, project: project, workspace: workspace})
       when is_list(tree) and not is_nil(project) do
    case Enum.find(tree, &(&1.id == project.id)) do
      %{workspaces: wss} ->
        Enum.map(wss, fn ws ->
          %{
            label: ws.name,
            href: "/projects/#{project.id}/workspaces/#{ws.id}",
            active?: ws.id == workspace.id
          }
        end)

      _ ->
        []
    end
  end

  defp workspace_items(_), do: []

  def agent_header(assigns) do
    # Desktop-only. On mobile the agent's identity + Info live in Row 2 of the
    # chat_header (the current-item bar) and the full detail is in the right rail
    # on lg+ — so this header is just the name + lifecycle controls at lg+.
    ~H"""
    <div class="hidden lg:block flex-none border-b border-zinc-200 dark:border-zinc-700/80">
      <div class="flex items-center justify-between px-5 h-12 gap-3">
        <%!-- Identity left, timestamp pushed to the RIGHT of this zone — same
    anatomy as the prompt band and the queue band, so "who/what" and
    "when" always live in the same two places. --%>
        <div class="flex items-center gap-3 min-w-0 flex-1">
          <.dot color={status_dot(@agent.status)} />
          <span class="text-base font-semibold text-zinc-900 dark:text-zinc-100 truncate">
            {@agent.name}
          </span>
          <div class="flex-1"></div>
          <span
            :if={@agent[:last_activity_at]}
            class="text-sm text-zinc-500 dark:text-zinc-400 flex-none"
          >
            {time_ago(@agent[:last_activity_at])}
          </span>
        </div>
        <div class="flex items-center gap-2 flex-none">
          <%!-- Container lifecycle is DESTRUCTIVE (Stop kills the container; Remove
    deletes the agent). On phones you interrupt with the red pill above
    the input and start/remove from the agents switcher. --%>
          <div class="flex items-center gap-2">
            <%!-- No Stop here. The live status row above the composer already
    carries one, right where you're watching the turn happen — two Stops
    on one screen is a second place to look for the same control. --%>
            <.control_btn
              :if={agent_display_status(@agent) in [:sleeping, :crashed]}
              variant={:primary}
              phx-click="start_agent"
              phx-value-id={@agent.id}
            >
              Start
            </.control_btn>
            <.control_btn
              :if={agent_display_status(@agent) in [:sleeping, :crashed]}
              phx-click="remove_agent"
              phx-value-id={@agent.id}
            >
              Remove
            </.control_btn>
            <span
              :if={@agent.status == :destroying}
              class="text-sm font-medium text-red-400 px-2 py-1"
            >
              Destroying...
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @detail_levels [
    {:trace, "All", "Reasoning + tool calls + full output"},
    {:actions, "Actions", "Reasoning + tool calls; output one click away"},
    {:chat, "Chat", "Just the conversation"}
  ]

  @doc """
  Segmented control for how much of the agent's inner work to show. Starts at
  :trace (maximum visibility / trust); lower levels collapse a layer at a time,
  and you can always switch back up to drill into history. The `DetailLevel`
  hook persists the choice to localStorage and restores it on connect.
  """
  attr :level, :atom, required: true

  def detail_level_control(assigns) do
    assigns = assign(assigns, :levels, @detail_levels)

    ~H"""
    <div
      id="detail-level"
      phx-hook="DetailLevel"
      data-level={@level}
      class="hidden sm:inline-flex items-center rounded-sm bg-zinc-100 dark:bg-zinc-800 p-1"
      role="group"
      aria-label="Activity detail level"
    >
      <button
        :for={{value, label, hint} <- @levels}
        phx-click="set_detail_level"
        phx-value-level={value}
        title={hint}
        aria-pressed={@level == value}
        class={Nav.seg_item_class(@level == value)}
      >
        {label}
      </button>
    </div>
    """
  end
end
