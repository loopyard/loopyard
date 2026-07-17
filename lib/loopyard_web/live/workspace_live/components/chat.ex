defmodule LoopyardWeb.Live.WorkspaceLive.Components.Chat do
  @moduledoc "Chat panel components: agent_view, agent_header, chat_panel, thinking_indicator, container_panel."
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias LoopyardWeb.Components.Nav

  import LoopyardWeb.Components.Common, only: [dot: 1, control_btn: 1, sound_control: 1]
  import LoopyardWeb.Components.Sidebar, only: [status_dot: 1, agent_display_status: 1]

  import LoopyardWeb.Live.WorkspaceLive.Messages,
    only: [chat_msg: 1, streaming_bubble: 1, streaming_thinking: 1, run_header: 1]

  import LoopyardWeb.Components.Icon

  import LoopyardWeb.Live.WorkspaceLive.Components.Formatters, only: [time_ago: 1]

  alias LoopyardWeb.Live.WorkspaceLive.Components.ChatStatus

  # The live-status presentation (thinking feed, live tail, Reasoning Bar) lives
  # in the ChatStatus sub-module to keep this file under its size cap. Re-expose
  # the public component functions so chat_panel's `<.thinking_indicator/>` /
  # `<.live_status/>` calls and the `Chat.current_turn_activity/1` tests are
  # unchanged.
  defdelegate thinking_indicator(assigns), to: ChatStatus
  defdelegate live_status(assigns), to: ChatStatus
  defdelegate reasoning_bar(assigns), to: ChatStatus
  defdelegate current_turn_activity(messages), to: ChatStatus

  # Build the breadcrumb trail for this workspace view.
  #   Loopyard / {project.name} / {workspace label}
  #
  # The trailing crumb is whatever the workspace's Source adapter
  # decides — branch name for Local, eventually `owner/repo#branch`
  # for GitHub. The label is owned by the adapter so the UI never
  # invents one. It links to the workspace overview (`base_path`) on
  # every sub-route so users can jump back from agents / services /
  # volumes. On the overview itself (`live_action == :index`) the
  # path is `nil`, which the Breadcrumbs component renders as the
  # current page (no link, aria-current="page").
  def chat_header(assigns) do
    # The mobile workspace header (phone-only; desktop navigates from the rails).
    # Two rows that mirror the hierarchy Root → Project → Workspace →
    # { Agents · Services · Repo }:
    #
    #   Row 1  ←  Loopyard / uncringe .................... 🔊   (WHERE you are)
    #   Row 2  [ Agents · Services · Repo ]  ● my-agent · Ready  Switch ⌄  (WHAT)
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
      |> assign(:ws_name, (assigns[:workspace_entry] || %{})[:name] || assigns.workspace.id)

    assigns =
      assigns
      |> assign(:section_tabs, section_tabs(assigns))
      |> assign(:project_items, project_items(assigns))
      |> assign(:workspace_items, workspace_items(assigns))

    assigns = assign(assigns, :can_switch, length(assigns.project_items) > 1 || length(assigns.workspace_items) > 1)

    # The workspace's primary reachable app port (exposed → has a URL), so the
    # phone header can offer a one-tap "open the running app" — otherwise ports
    # are buried in the Services tab on mobile.
    assigns = assign(assigns, :app_port, current_ws_port(assigns[:global_tree], assigns.workspace.id))

    ~H"""
    <div class="md:hidden">
      <%!-- Row 1: WHERE you are — back out + Project / Workspace + sound. Tapping
           either name throws open ONE full-screen switcher of every project and
           its workspaces (pick any to jump; ✕ / backdrop to bail). No pop-overs. --%>
      <Nav.bar height="h-12" pad="px-2" gap="gap-1.5">
        <Nav.back_button navigate="/workspaces" label="Back to workspaces" />
        <nav class="flex-1 min-w-0 flex items-center gap-1.5 text-lg" aria-label="Location">
          <Nav.crumb
            :if={@project}
            id="nav-switcher"
            label={@project.name}
            switch?={@can_switch}
            chevron={false}
            href={"/projects/#{@project.id}"}
          />
          <span :if={@project} class="text-zinc-300 dark:text-zinc-600 flex-none">/</span>
          <Nav.crumb id="nav-switcher" label={@ws_name} current switch?={@can_switch} />
        </nav>
        <:actions>
          <%!-- Agent details: opens the context panel (usage / changes / status)
               as a bottom sheet, since the right rail is desktop-only. Only when
               an agent is selected. --%>
          <button
            :if={@selected_agent}
            type="button"
            phx-click={Nav.open_sheet("agent-context")}
            aria-label="Agent details"
            class="focus-ring inline-flex items-center justify-center w-11 h-11 rounded-lg text-zinc-400 dark:text-zinc-500 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
          >
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="w-5 h-5">
              <rect x="3" y="4" width="18" height="16" rx="2" />
              <line x1="15" y1="4" x2="15" y2="20" />
            </svg>
          </button>
          <%!-- One-tap open the running app: the workspace's exposed port URL,
               reachable from this phone (only shows when a port is network-open). --%>
          <.link
            :if={@app_port}
            href={@app_port.url}
            target="_blank"
            rel="noopener"
            aria-label={"Open app on port #{@app_port.port}"}
            class="focus-ring inline-flex items-center justify-center gap-0.5 h-11 px-2.5 rounded-lg font-mono text-sm text-emerald-600 dark:text-emerald-400 hover:bg-emerald-500/10 active:bg-emerald-500/20 transition-colors flex-none"
          >
            :{@app_port.port} <span class="text-xs opacity-70">↗</span>
          </.link>
          <.sound_control id="sound-workspace" />
        </:actions>
      </Nav.bar>

      <Nav.switcher_sheet :if={@can_switch} id="nav-switcher" title="Switch workspace">
        <:current>
          <span :if={@project} class="flex-none text-zinc-400 dark:text-zinc-500 truncate">
            {@project.name} /
          </span>
          <span class="flex-1 min-w-0 truncate font-semibold text-zinc-900 dark:text-zinc-100">
            {@ws_name}
          </span>
        </:current>
        <LoopyardWeb.Components.ProjectList.project_groups
          projects={@global_tree}
          current_workspace_id={@workspace.id}
          row_click={JS.hide(to: "#nav-switcher")}
        />
      </Nav.switcher_sheet>

      <%!-- Row 2: WHAT you're looking at — section tabs + the current item, which
           taps open a full-screen switcher of siblings. --%>
      <Nav.section_switcher
        id="item-switcher"
        title={section_title(@active)}
        current={@current}
        items={@items}
      >
        <:tabs>
          <Nav.segmented items={@section_tabs} label="Workspace section" />
        </:tabs>
        <:extra>
          <.link
            :if={@active == :agents}
            patch={"#{@base_path}/new"}
            phx-click={JS.hide(to: "#item-switcher")}
            class="flex items-center gap-2 px-3 min-h-[2.75rem] rounded-lg text-sm font-medium text-violet-600 dark:text-violet-400 active:bg-violet-50 dark:active:bg-violet-500/10"
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

  # Title for the full-screen item switcher, by active category.
  defp section_title(:services), do: "Switch service"
  defp section_title(:volumes), do: "Switch repo"
  defp section_title(_), do: "Switch agent"

  # The section tabs for Row 2 — Agents is always present, Services / Repo only
  # when the workspace actually has them. Empty on the "new agent" route (nothing
  # to switch between yet). `Nav.segmented` hides itself when the list is empty.
  defp section_tabs(%{live_action: :new}), do: []

  # The workspace's first reachable (network-exposed) app port from the global
  # tree — `%{port, url}` or nil. Used for the phone header's open-app button.
  defp current_ws_port(nil, _ws_id), do: nil

  defp current_ws_port(tree, ws_id) do
    tree
    |> Enum.flat_map(& &1.workspaces)
    |> Enum.find(&(&1.id == ws_id))
    |> case do
      %{ports: [p | _]} -> p
      _ -> nil
    end
  end

  defp section_tabs(a) do
    [%{label: "Agents", active?: a.active == :agents, patch: a.agents_href}] ++
      if(a.service_statuses != [],
        do: [%{label: "Services", active?: a.active == :services, patch: a.services_href}],
        else: []
      ) ++
      if(a.volumes != [],
        # "Files" (not "Repo" — too narrow): this surface is heading toward the
        # code's current state + changes + the files in the container, not just a
        # git repo. See the Files-unification follow-up.
        do: [%{label: "Files", active?: a.active == :volumes, patch: a.volumes_href}],
        else: []
      )
  end

  # Which workspace category the current route belongs to — drives the active
  # pill. Every agent sub-view (chat/container/info/context) is "Agents"; every
  # service/console route is "Services"; every volume/git/sync route is "Volumes".
  defp active_category(action)
       when action in [:service, :services, :console],
       do: :services

  defp active_category(action)
       when action in [
              :volume,
              :volume_files_root,
              :volume_file,
              :volume_git,
              :git_diff,
              :git_staged_diff,
              :git_commit,
              :git_commit_file,
              :sync
            ],
       do: :volumes

  defp active_category(_), do: :agents

  # Content-first target for a category tab: the last item you had open there,
  # else that category's list (or its first item when there's no list route).
  defp category_href(:agents, %{nav_agent_id: id, base_path: bp}) when is_binary(id),
    do: "#{bp}/agents/#{id}"

  defp category_href(:agents, %{agents: [a | _], base_path: bp}), do: "#{bp}/agents/#{a.id}"

  defp category_href(:agents, %{base_path: bp}), do: bp

  defp category_href(:services, %{nav_service: s, base_path: bp}) when is_binary(s),
    do: "#{bp}/services/#{s}"

  defp category_href(:services, %{service_statuses: [s | _], base_path: bp}),
    do: "#{bp}/services/#{s.name}"

  defp category_href(:services, %{base_path: bp}), do: "#{bp}/services"

  defp category_href(:volumes, %{nav_volume: v, base_path: bp}) when is_binary(v),
    do: "#{bp}/volumes/#{v}"

  defp category_href(:volumes, %{volumes: [vol | _], base_path: bp}),
    do: "#{bp}/volumes/#{vol_name(vol)}"

  defp category_href(:volumes, %{base_path: bp}), do: bp

  defp vol_name(vol), do: Map.get(vol, :name) || Map.get(vol, "name")

  # Items of the active category for the switcher, each with a label, route,
  # status dot, one-word detail, and whether it's the one currently open.
  defp category_items(%{active: :agents, agents: agents, base_path: bp, nav_agent_id: cur}) do
    Enum.map(agents, fn a ->
      %{
        label: Map.get(a, :name) || a.id,
        href: "#{bp}/agents/#{a.id}",
        active?: a.id == cur,
        dot: status_dot(a.status),
        detail: status_word(a)
      }
    end)
  end

  defp category_items(%{
         active: :services,
         service_statuses: svcs,
         base_path: bp,
         nav_service: cur
       }) do
    Enum.map(svcs, fn s ->
      %{
        label: s.name,
        href: "#{bp}/services/#{s.name}",
        active?: s.name == cur,
        dot: svc_dot(s),
        detail: svc_word(s)
      }
    end)
  end

  defp category_items(%{active: :volumes, volumes: vols, base_path: bp, nav_volume: cur}) do
    Enum.map(vols, fn v ->
      n = vol_name(v)

      %{
        label: vol_label(n),
        href: "#{bp}/volumes/#{n}",
        active?: n == cur,
        dot: "bg-blue-400",
        detail: nil
      }
    end)
  end

  defp category_items(_), do: []

  # The single currently-selected item of the active category, for Row 2. nil →
  # nothing is selected in this category yet (e.g. on a list), so Row 2 hides.
  defp current_item(%{active: :agents, agents: agents, nav_agent_id: id}) do
    case Enum.find(agents, &(&1.id == id)) do
      nil ->
        nil

      ag ->
        # No changed-files badge here — a bare "● 25" in the header read as a
        # mystery. The agent's live status (Ready / Working / Thinking) is the
        # useful signal; the changes count lives in the right-rail "Changes".
        %{
          label: Map.get(ag, :name) || ag.id,
          dot: status_dot(ag.status),
          detail: status_word(ag),
          tone: status_tone(ag),
          badge: nil
        }
    end
  end

  defp current_item(%{active: :services, service_statuses: svcs, nav_service: name}) do
    case Enum.find(svcs, &(&1.name == name)) do
      nil ->
        nil

      s ->
        %{
          label: s.name,
          dot: svc_dot(s),
          detail: svc_word(s),
          tone: "text-zinc-400 dark:text-zinc-500",
          badge: nil
        }
    end
  end

  defp current_item(%{active: :volumes, volumes: vols, nav_volume: name}) do
    case Enum.find(vols, &(vol_name(&1) == name)) do
      nil ->
        nil

      v ->
        %{label: vol_label(vol_name(v)), dot: "bg-blue-400", detail: nil, tone: nil, badge: nil}
    end
  end

  defp current_item(_), do: nil

  # A code-volume name like "loopyard-abcd-code" → its meaningful tail ("code").
  defp vol_label(name) when is_binary(name), do: name |> String.split("-") |> List.last()
  defp vol_label(name), do: to_string(name)

  defp svc_dot(%{status: :running}), do: "bg-emerald-500"
  defp svc_dot(%{status: s}) when s in [:restarting, :starting], do: "bg-amber-500 animate-pulse"
  defp svc_dot(_), do: "bg-zinc-400"

  defp svc_word(%{status: s}) when is_atom(s) and not is_nil(s),
    do: s |> to_string() |> String.capitalize()

  defp svc_word(_), do: nil

  # --- Agent View ---

  def agent_view(assigns) do
    ~H"""
    <div class="flex-1 flex min-h-0">
      <%!-- Center pane. The mobile category switcher lives in the top back bar
           now; the agent's Info folds into the header — so this pane is just the
           chat (or the container view). Agents / Services / Volumes are reached
           by the tab bar, which routes services/volumes to their own screens. --%>
      <div class="flex-1 flex flex-col min-w-0 min-h-0">
        <.agent_header
          agent={@selected_agent}
          has_container={@has_container}
          base_path={@base_path}
          changes={@changes}
          detail_level={@detail_level}
        />
        <.chat_panel
          :if={@tab != :container}
          messages={@messages}
          streaming_text={@streaming_text}
          streaming_thinking={@streaming_thinking}
          agent={@selected_agent}
          workspace_id={@workspace.id}
          host={@host}
          thinking_word={@thinking_word}
          has_more_messages={@has_more_messages}
          window_tail?={@window_tail?}
          detail_level={@detail_level}
        />
        <.container_panel
          :if={@tab == :container}
          env={@container_env}
          logs={@container_logs}
          log_service={@container_log_service}
          has_container={@has_container}
        />
      </div>
    </div>
    """
  end

  def agent_header(assigns) do
    # Desktop-only. On mobile the agent's identity + Info live in Row 2 of the
    # chat_header (the current-item bar) and the full detail is in the right rail
    # on lg+ — so this header is just the name + lifecycle controls at lg+.
    ~H"""
    <div class="hidden lg:block flex-none border-b border-zinc-200 dark:border-zinc-700/80">
      <div class="flex items-center justify-between px-5 h-12 gap-3">
        <div class="flex items-center gap-3 min-w-0 flex-1">
          <.dot color={status_dot(@agent.status)} />
          <span class="text-base font-semibold text-zinc-900 dark:text-zinc-100 truncate">
            {@agent.name}
          </span>
          <span
            :if={@agent[:last_activity_at]}
            class="text-sm text-zinc-400 dark:text-zinc-500 flex-none"
          >
            {time_ago(@agent[:last_activity_at])}
          </span>
        </div>
        <div class="flex items-center gap-2 flex-none">
          <%!-- Container lifecycle is DESTRUCTIVE (Stop kills the container; Remove
               deletes the agent). On phones you interrupt with the red pill above
               the input and start/remove from the agents switcher. --%>
          <div class="flex items-center gap-2">
            <%!-- Stop = interrupt the RUNNING turn. Only shown while the agent is
                 actually working — an idle "Stop" is meaningless ("stop what?"). --%>
            <.control_btn
              :if={agent_display_status(@agent) == :thinking}
              phx-click="interrupt_agent"
              phx-value-id={@agent.id}
            >
              Stop
            </.control_btn>
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

  # Plain-language status word + tone for the folded mobile Info summary.
  defp status_word(agent) do
    case agent_display_status(agent) do
      :thinking -> "Working"
      :idle -> "Ready"
      s when s in [:sleeping, :crashed] -> "Asleep"
      other -> other |> to_string() |> String.capitalize()
    end
  end

  defp status_tone(agent) do
    case agent_display_status(agent) do
      :thinking -> "text-violet-600 dark:text-violet-400"
      :idle -> "text-emerald-600 dark:text-emerald-400"
      _ -> "text-zinc-500 dark:text-zinc-400"
    end
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
      class="hidden sm:inline-flex items-center rounded-lg bg-zinc-100 dark:bg-zinc-800 p-1"
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

  # --- Chat Panel ---

  def chat_panel(assigns) do
    # While the agent is working, its in-progress tool calls are shown in the
    # live activity feed (thinking_indicator) — so suppress the SAME rows here
    # to avoid double-listing. They render inline normally once the turn ends.
    assigns = assign(assigns, :live_tool_from, active_turn_cutoff(assigns))
    assigns = assign_new(assigns, :window_tail?, fn -> true end)

    ~H"""
    <div class="relative flex-1 flex flex-col min-h-0">
      <%!-- Windowed transcript: when you've scrolled up into history, the live
           tail isn't loaded. This snaps you back to the newest messages. --%>
      <button
        :if={not @window_tail?}
        phx-click="load_latest"
        class="absolute bottom-3 left-1/2 -translate-x-1/2 z-10 inline-flex items-center gap-1.5 rounded-full bg-violet-600 text-white text-sm font-medium px-3.5 py-1.5 shadow-lg shadow-violet-900/20 hover:bg-violet-700 transition-colors"
      >
        Jump to latest
        <svg viewBox="0 0 20 20" fill="currentColor" class="w-3.5 h-3.5">
          <path
            fill-rule="evenodd"
            d="M10 3a.75.75 0 0 1 .75.75v9.19l3.72-3.72a.75.75 0 1 1 1.06 1.06l-5 5a.75.75 0 0 1-1.06 0l-5-5a.75.75 0 1 1 1.06-1.06l3.72 3.72V3.75A.75.75 0 0 1 10 3Z"
            clip-rule="evenodd"
          />
        </svg>
      </button>
      <%!-- scroll-smooth: the auto-tail (ScrollBottom hook nudges scrollTop as the
           agent streams) animates instead of jumping, so following the thinking
           glides. Pure CSS — honors prefers-reduced-motion automatically. --%>
      <div id="messages" class="flex-1 overflow-y-auto flex flex-col px-4 md:px-6 pb-4">
        <%!-- `mt-auto` anchors the transcript to the BOTTOM: the most recent
             message sits just above the input on first paint, so there's no
             post-load scroll jump (that animated slide-down was the jank).
             Older messages load in chunks as you scroll up (ScrollBottom hook →
             load_more). Normal flow (NOT col-reverse) so the human prompts can
             `position: sticky` to the top of their section. --%>
        <div class="space-y-2 mt-auto">
          <%!-- Progressive loader: while there's older history above the window,
               a soft shimmer sits at the very top. Scroll into it and load_more
               fetches the next batch (prepended below this, so it stays put);
               when you reach the start it disappears. Gentler than a hard
               "Loading…" flash. --%>
          <div :if={assigns[:has_more_messages]} class="space-y-2.5 py-3" aria-hidden="true">
            <div class="h-3 w-20 rounded bg-zinc-200/80 dark:bg-zinc-700/50 animate-pulse"></div>
            <div class="h-3.5 w-3/4 rounded bg-zinc-200/70 dark:bg-zinc-700/40 animate-pulse"></div>
            <div class="h-3.5 w-1/2 rounded bg-zinc-200/70 dark:bg-zinc-700/40 animate-pulse"></div>
          </div>
          <%!-- Split into SECTIONS: each human prompt + the response it owns. The
               prompt is `sticky top-0` WITHIN its <section>, so it pins while you
               scroll its response and then RELEASES at the section boundary as the
               next prompt's section takes over — prompts replace each other
               instead of stacking. Pure CSS; the normal-flow scroll (not
               col-reverse) is what makes the per-section sticky pin flush. --%>
          <%= for section <- LoopyardWeb.Live.WorkspaceLive.Messages.transcript_sections(@messages) do %>
            <section>
              <%= if section.prompt do %>
                <% {pmsg, pidx} = section.prompt %>
                <.chat_msg
                  msg={pmsg}
                  idx={pidx}
                  messages={@messages}
                  agent_id={@agent.id}
                  workspace_id={@workspace_id}
                  host={@host}
                  detail_level={@detail_level}
                />
              <% end %>
              <%= for group <- section.body do %>
                <%= case group do %>
                  <% {:break, {msg, idx}} -> %>
                    <.chat_msg
                      :if={not in_live_feed?(@live_tool_from, msg, idx)}
                      msg={msg}
                      idx={idx}
                      messages={@messages}
                      agent_id={@agent.id}
                      workspace_id={@workspace_id}
                      host={@host}
                      detail_level={@detail_level}
                    />
                  <% {:run, items} -> %>
                    <div class="mt-3">
                      <.run_header timestamp={run_timestamp(items)} />
                      <div>
                        <.chat_msg
                          :for={{msg, idx} <- items}
                          :if={not in_live_feed?(@live_tool_from, msg, idx)}
                          msg={msg}
                          idx={idx}
                          messages={@messages}
                          agent_id={@agent.id}
                          workspace_id={@workspace_id}
                          host={@host}
                          detail_level={@detail_level}
                        />
                      </div>
                    </div>
                <% end %>
              <% end %>
            </section>
          <% end %>
          <%!-- Live tail: the agent's in-progress work on ONE continuous rail. A
               single line runs from the Claude icon's CENTER straight down through
               the reasoning and into the live status — one unbroken timeline. The
               icon + "Claude" label show only when this is the top of the response
               (pure thinking); once the section above owns the header, just the line
               continues. --%>
          <div
            :if={
              @streaming_text != "" || (assigns[:streaming_thinking] || "") != "" ||
                @agent.status in [:backoff, :compacting] ||
                (@agent.status == :thinking && not awaiting_answer?(@messages) &&
                   not awaiting_approval?(@messages) && not building?(@messages))
            }
            class=""
          >
            <%!-- No timeline rail — the live turn uses the SAME left-aligned header
                 (inline sparkle + "Claude · HH:MM") as completed turns and lets its
                 content sit flush at the gutter, so nothing is indented under a
                 vertical line. Header shows only at the top of the response. --%>
            <.run_header
              :if={not turn_started_rendering?(@messages)}
              timestamp={current_turn_timestamp(@messages)}
            />

            <.streaming_thinking
              :if={
                @detail_level != :chat && assigns[:streaming_thinking] != "" &&
                  assigns[:streaming_thinking] != nil
              }
              text={@streaming_thinking}
            />
            <.streaming_bubble :if={@streaming_text != ""} text={@streaming_text} />
            <.thinking_indicator
              :if={
                @agent.status == :thinking && @streaming_text == "" &&
                  (assigns[:streaming_thinking] || "") == "" &&
                  not awaiting_answer?(@messages) && not awaiting_approval?(@messages) &&
                  not building?(@messages)
              }
              messages={@messages}
              word={@thinking_word}
            />
            <.live_status
              :if={@agent.status in [:thinking, :backoff, :compacting]}
              messages={@messages}
              word={@thinking_word}
              agent_id={@agent.id}
              mode={live_status_mode(@agent)}
              streaming_text={@streaming_text}
              active_tool={@agent[:active_tool]}
              tokens={(@agent[:total_input_tokens] || 0) + (@agent[:total_output_tokens] || 0)}
            />
          </div>
        </div>
      </div>
      <%!-- The composer: queue + Reasoning Bar + input, grouped as ONE unit. The
            input lives in its own phx-update="ignore" wrapper (the ChatForm hook
            owns flush/ack/mobile/Enter — do NOT move it inside something LV
            patches). The queue and the always-visible Reasoning Bar sit above it,
            LiveView-updated, so you can keep queuing and watch progress while the
            agent works. --%>
      <div class="flex-none border-t border-zinc-200 dark:border-zinc-700/80 p-3 md:p-4 space-y-2">
        <%!-- The queue is a quiet, COMPACT list waiting for the agent to pick up
              next — kept dense (small text, tight rows, no card chrome) so a few
              stacked don't dominate the composer. Tap a row to pull it back into
              the box and edit it. --%>
        <div :if={(@agent[:pending_count] || 0) > 0} class="space-y-0.5">
          <div class="flex items-center justify-between px-0.5">
            <span class="text-xs font-medium uppercase tracking-wide text-violet-500/80 dark:text-violet-400/80">
              Queued · sends when the agent finishes
            </span>
            <button
              type="button"
              phx-click="clear_pending"
              phx-value-id={@agent.id}
              class="focus-ring text-xs text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"
            >
              Clear all
            </button>
          </div>
          <div
            :for={{text, i} <- Enum.with_index(@agent[:pending_messages] || [])}
            class="group/q flex items-center gap-1.5 rounded-md border border-zinc-200/60 dark:border-zinc-700/50 bg-zinc-50 dark:bg-zinc-800/40 px-2.5 py-1"
          >
            <button
              type="button"
              phx-click="edit_pending"
              phx-value-id={@agent.id}
              phx-value-index={i}
              title="Edit — pull back into the message box"
              class="focus-ring flex-1 min-w-0 text-left truncate text-sm text-zinc-600 dark:text-zinc-300"
            >
              {text}
            </button>
            <button
              type="button"
              phx-click="remove_pending"
              phx-value-id={@agent.id}
              phx-value-index={i}
              title="Remove from queue"
              class="focus-ring flex-none w-5 h-5 rounded flex items-center justify-center text-zinc-400 hover:text-red-500 hover:bg-red-500/10 opacity-0 group-hover/q:opacity-100 transition-opacity"
            >
              ✕
            </button>
          </div>
        </div>
        <%!-- Auto-compaction is house-keeping the user shouldn't have to care about:
           no pre-warning, and only a tiny muted marker WHILE it's actually
           happening (≥92%). It's automatic and lossless (full history is kept),
           so it never needs a sentence or an alarm. --%>
        <div
          :if={(@agent[:context_utilization] || 0.0) >= 0.92}
          class="flex items-center gap-1.5 text-sm text-zinc-400 dark:text-zinc-500"
        >
          <span class="flex-none">🗜</span>
          <span class="min-w-0">Compacting…</span>
        </div>
        <div id="chat-form-wrapper" phx-update="ignore">
          <form
            id="chat-form"
            phx-submit="send_message"
            phx-hook="ChatForm"
            class="flex items-end gap-2"
          >
            <textarea
              name="message"
              id="chat-input"
              rows="1"
              placeholder="Type a message..."
              autocomplete="off"
              class="flex-1 rounded-xl border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-4 py-2.5 text-base
                   text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 resize-none
                   focus:outline-none focus:ring-2 focus:ring-violet-500/20 focus:border-violet-400"
            ></textarea>
            <button
              type="submit"
              aria-label="Send"
              class="focus-ring flex-none flex items-center justify-center rounded-xl bg-violet-600 hover:bg-violet-700 w-11 h-11 text-white transition-colors"
            >
              <.icon name={:arrow_up} class="w-5 h-5" />
            </button>
          </form>
          <%!-- Why a send failed — the ChatForm hook fills + reveals this so a
              rejected send is never just a silent red flash. --%>
          <p id="send-status" class="hidden mt-1.5 text-sm text-red-500 dark:text-red-400"></p>
        </div>
      </div>
    </div>
    """
  end

  # True when the most recent question card is still unanswered. While it
  # is, the agent's turn is parked inside ask_user waiting on the human —
  # so the "Asking…" bouncing-dots indicator is redundant with the card
  # (which already says "The agent needs your input"). Suppress the dots.
  defp awaiting_answer?(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&(&1.role == :question))
    |> case do
      %{status: :pending} -> true
      _ -> false
    end
  end

  # True when the most recent approval card is still pending. Like the question
  # case, the agent's turn is parked inside propose_* waiting on the human, so the
  # "Awaiting approval…" dots are redundant with the Approve/Deny card itself.
  defp awaiting_approval?(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find(&(&1.role == :approval))
    |> case do
      %{status: :pending} -> true
      _ -> false
    end
  end

  # True when a command is actively streaming into its own build bubble (the
  # latest message is an in-flight role: :build, not yet :build_done/:build_failed).
  # While it is, that bubble — with its live output + elapsed timer — IS the
  # "watch it work" surface, so the generic "Twirling…" indicator echoing the
  # same command is redundant. Suppress it.
  defp building?(messages) do
    match?(%{role: :build}, List.last(messages))
  end

  # What the harness is doing right now, for the live bar's word + colour. The
  # agent sets :backoff while restarting a crashed CLI and :compacting while it
  # summarizes a full context; everything else reads as the model thinking.
  defp live_status_mode(agent) do
    case agent.status do
      :backoff -> :restarting
      :compacting -> :compacting
      _ -> :thinking
    end
  end

  # The current turn's start time (the last human message) — for the live tail's
  # "Claude · HH:MM" header so it reads the same as a finished run.
  defp current_turn_timestamp(messages) do
    case Enum.reverse(messages) |> Enum.find(&(&1.role == :user)) do
      %{timestamp: %DateTime{} = ts} -> ts
      _ -> nil
    end
  end

  # True once the current turn has produced ANY message after the prompt — at which
  # point the section above renders the "Claude" header for that content, so the
  # live tail must NOT render its own (that's the duplicate). False during a pure
  # prefill/think with nothing rendered yet, where the live tail IS the top of the
  # response and owns the header.
  defp turn_started_rendering?(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(&(&1.role != :user))
    |> Enum.any?()
  end

  # Index of the last human message — tools after it belong to the active
  # turn and live in the feed. Returns nil (suppress nothing) unless the
  # feed is actually on screen, so a tool row is never hidden with no home.
  defp active_turn_cutoff(assigns) do
    if thinking_feed_visible?(assigns) do
      assigns.messages
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(-1, fn {m, i} -> if m.role == :user, do: i end)
    end
  end

  defp thinking_feed_visible?(assigns) do
    assigns.agent.status == :thinking and
      (assigns[:streaming_text] || "") == "" and
      (assigns[:streaming_thinking] || "") == "" and
      not awaiting_answer?(assigns.messages) and
      not awaiting_approval?(assigns.messages) and
      not building?(assigns.messages)
  end

  defp in_live_feed?(nil, _msg, _idx), do: false
  defp in_live_feed?(from, msg, idx), do: idx > from and msg.role in [:tool, :tool_result]

  # The "Claude · HH:MM" header timestamp for a run = the first message in it.
  defp run_timestamp([{%{timestamp: ts}, _idx} | _]), do: ts
  defp run_timestamp(_), do: nil

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
        <button
          phx-click="refresh_container"
          class="text-sm text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors"
        >
          Refresh
        </button>
      </div>
      <div :if={@env} class="border-b border-zinc-200 dark:border-zinc-700/80">
        <div class="px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50">
          <h3 class="text-sm font-semibold uppercase tracking-wider text-zinc-500">Environment</h3>
        </div>
        <pre class="px-4 py-3 text-sm font-mono text-zinc-600 dark:text-zinc-400 overflow-x-auto whitespace-pre-wrap max-h-48 overflow-y-auto">{@env}</pre>
      </div>
      <div class="flex-1 flex flex-col min-h-0">
        <div class="flex items-center justify-between px-4 py-2 bg-zinc-50 dark:bg-zinc-800/50 border-b border-zinc-200 dark:border-zinc-700/80">
          <h3 class="text-sm font-semibold uppercase tracking-wider text-zinc-500">Logs</h3>
          <form phx-change="filter_container_service" class="inline">
            <input
              type="text"
              name="service"
              value={@log_service || ""}
              placeholder="Filter service..."
              class="text-sm rounded border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-2 py-1 w-28
                     focus:outline-none focus:ring-1 focus:ring-violet-500/30"
            />
          </form>
        </div>
        <pre class="flex-1 px-4 py-3 text-sm font-mono overflow-auto whitespace-pre-wrap bg-zinc-100 dark:bg-zinc-950 text-zinc-800 dark:text-green-400 min-h-[200px]">{@logs}</pre>
      </div>
    </div>
    """
  end
end
