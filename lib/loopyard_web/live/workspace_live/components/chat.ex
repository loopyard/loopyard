defmodule LoopyardWeb.Live.WorkspaceLive.Components.Chat do
  @moduledoc "Chat panel components: agent_view, agent_header, chat_panel, thinking_indicator, container_panel."
  use Phoenix.Component

  import LoopyardWeb.Components.Common, only: [dot: 1, control_btn: 1]
  import LoopyardWeb.Components.Sidebar, only: [status_dot: 1, agent_display_status: 1]

  import LoopyardWeb.Live.WorkspaceLive.Messages,
    only: [chat_msg: 1, streaming_bubble: 1, streaming_thinking: 1, run_header: 1]

  import LoopyardWeb.Components.Icon

  import LoopyardWeb.Live.WorkspaceLive.Components.Formatters, only: [time_ago: 1]

  import LoopyardWeb.Live.WorkspaceLive.Components.ContextPanel,
    only: [context_sections: 1]

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
    # No top chrome on the workspace view (breadcrumb / Remote / user / System
    # live at `/` now). On desktop the left rail's "Loopyard" wordmark is the
    # way home; the rail is hidden on mobile, so we keep a thin back-bar here.
    #
    # Mobile back → the birdseye at `/`, which IS the mega switcher: bounce
    # across every project → workspace → agent. Switching AGENTS within this
    # workspace stays on the "Info" tab, so back is unambiguously "up and out."
    # (Patching to the workspace :index doesn't work — its landing logic
    # auto-redirects straight back to an agent, so the button appears dead.)
    ~H"""
    <div class="md:hidden flex items-center h-12 px-2 flex-none border-b border-zinc-200 dark:border-zinc-700/80">
      <.link
        navigate="/"
        class="-ml-1 inline-flex items-center gap-1 px-2 py-1 rounded-md text-base font-medium text-violet-600 dark:text-violet-400 hover:bg-violet-50 dark:hover:bg-violet-500/10 active:bg-violet-100 dark:active:bg-violet-500/20 transition-colors flex-none min-w-0"
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          viewBox="0 0 20 20"
          fill="currentColor"
          class="w-5 h-5 flex-none"
        >
          <path
            fill-rule="evenodd"
            d="M17 10a.75.75 0 0 1-.75.75H5.612l4.158 3.96a.75.75 0 1 1-1.04 1.08l-5.5-5.25a.75.75 0 0 1 0-1.08l5.5-5.25a.75.75 0 1 1 1.04 1.08L5.612 9.25H16.25A.75.75 0 0 1 17 10Z"
            clip-rule="evenodd"
          />
        </svg>
        <span class="truncate">Projects</span>
      </.link>
    </div>
    """
  end

  # --- Agent View ---

  def agent_view(assigns) do
    ~H"""
    <div class="flex-1 flex min-h-0">
      <%!-- Main content: hidden on mobile when viewing context panel --%>
      <div class={[
        "flex-1 flex flex-col min-w-0 min-h-0",
        if(@tab == :context_panel, do: "hidden lg:flex", else: "flex")
      ]}>
        <.agent_header
          agent={@selected_agent}
          tab={@tab}
          has_container={@has_container}
          base_path={@base_path}
          detail_level={@detail_level}
        />
        <.chat_panel
          :if={@tab in [:chat, :context_panel]}
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
      <%!-- The desktop right rail (Agents + Services + Volumes + this agent's
           context) is hidden on phones, so the "Info" view IS that rail on
           mobile — the whole workspace in one scrollable, touch-sized panel.
           Tapping an agent switches to it; tapping a service opens it. --%>
      <div
        :if={@tab == :context_panel}
        class="flex-1 lg:hidden overflow-y-auto bg-zinc-50 dark:bg-zinc-900/50"
      >
        <LoopyardWeb.Components.SideNav.section label="Agents">
          <LoopyardWeb.Live.WorkspaceLive.Components.Sidebar.agent_list_item
            :for={a <- @agents}
            agent={a}
            selected={@selected_id == a.id}
          />
          <.link
            patch={"#{@base_path}/new"}
            class="flex items-center gap-2 px-3 min-h-[2.75rem] text-sm font-medium text-violet-600 dark:text-violet-400 active:bg-violet-50 dark:active:bg-violet-500/10"
          >
            + New agent
          </.link>
        </LoopyardWeb.Components.SideNav.section>
        <LoopyardWeb.Components.SideNav.section :if={@service_statuses != []} label="Services">
          <LoopyardWeb.Live.WorkspaceLive.Components.Sidebar.service_item
            :for={svc <- @service_statuses}
            svc={svc}
            base_path={@base_path}
            selected={@selected_service == svc.name}
            host={@host}
            workspace_id={@workspace.id}
          />
        </LoopyardWeb.Components.SideNav.section>
        <.context_sections agent={@selected_agent} editing_name={@editing_name} />
      </div>
    </div>
    """
  end

  def agent_header(assigns) do
    # Ports are now shown per-process in the sidebar, not per-agent
    port = nil
    assigns = assign(assigns, :container_port, port)

    ~H"""
    <div class="flex-none border-b border-zinc-200 dark:border-zinc-700/80">
      <div class="flex items-center justify-between px-3 md:px-5 h-12 gap-2">
        <div class="flex items-center gap-2 md:gap-3 min-w-0">
          <.dot color={status_dot(@agent.status)} />
          <span class="text-base font-semibold text-zinc-900 dark:text-zinc-100 truncate">
            {@agent.name}
          </span>
          <span
            :if={@agent[:last_activity_at]}
            class="text-xs text-zinc-400 dark:text-zinc-500 hidden sm:block flex-none"
          >
            {time_ago(@agent[:last_activity_at])}
          </span>
        </div>
        <div class="flex items-center gap-2 flex-none">
          <%!-- Agent context — mobile/tablet only (the right rail shows it on lg+).
               Real touch target (≈40px tall), and the only control on the phone
               header so it can't be fat-fingered into a destructive action. --%>
          <.link
            patch={"#{@base_path}/agents/#{@agent.id}/context"}
            class="lg:hidden inline-flex items-center min-h-[2.5rem] px-3 rounded-lg text-sm font-medium text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-700 active:bg-zinc-200 dark:active:bg-zinc-600 transition-colors"
            aria-label="Agent context, services, and info"
          >
            Info
          </.link>
          <%!-- Container lifecycle is DESTRUCTIVE (Stop kills the container; Remove
               deletes the agent) — keep it off the cramped phone header, where it
               sat one thumb-width from Info. On phones: interrupt a running turn
               with the big red pill above the input; start/remove a sleeping agent
               from the agents list (Menu). On md+ there's room, so show them. --%>
          <div class="hidden md:flex items-center gap-2">
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
              class="text-xs font-medium text-red-400 px-2 py-1"
            >
              Destroying...
            </span>
          </div>
        </div>
      </div>
      <div :if={@has_container} class="flex gap-0 px-4">
        <button
          phx-click="switch_tab"
          phx-value-tab="chat"
          class={"px-3 py-1.5 text-xs font-medium border-b-2 transition-colors #{if @tab == :chat, do: "border-violet-500 text-violet-600 dark:text-violet-400", else: "border-transparent text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"}"}
        >
          Chat
        </button>
        <button
          phx-click="switch_tab"
          phx-value-tab="container"
          class={"px-3 py-1.5 text-xs font-medium border-b-2 transition-colors #{if @tab == :container, do: "border-violet-500 text-violet-600 dark:text-violet-400", else: "border-transparent text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"}"}
        >
          Container
        </button>
        <.link
          patch={"#{@base_path}/agents/#{@agent.id}/context"}
          class={"lg:hidden px-3 py-1.5 text-xs font-medium border-b-2 transition-colors #{if @tab == :context_panel, do: "border-violet-500 text-violet-600 dark:text-violet-400", else: "border-transparent text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"}"}
        >
          Info
        </.link>
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
        class={[
          "px-3 py-1.5 text-sm font-medium rounded-md transition-colors",
          if(@level == value,
            do: "bg-white dark:bg-zinc-700 text-zinc-900 dark:text-zinc-100 shadow-sm",
            else: "text-zinc-500 dark:text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200"
          )
        ]}
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
        class="absolute bottom-3 left-1/2 -translate-x-1/2 z-10 inline-flex items-center gap-1.5 rounded-full bg-violet-600 text-white text-xs font-medium px-3.5 py-1.5 shadow-lg shadow-violet-900/20 hover:bg-violet-700 transition-colors"
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
            class="relative mt-3"
          >
            <%!-- The rail: icon on top, then a 1px line filling the rest of the
                 height. `items-center` centers the line in the w-5 column so it
                 passes straight through the icon's center and extends from its
                 bottom with no gap. --%>
            <div class="absolute left-0 top-0 bottom-1 w-5 flex flex-col items-center">
              <span
                :if={not turn_started_rendering?(@messages)}
                class="w-5 h-5 rounded-full bg-violet-100 dark:bg-violet-900/40 flex items-center justify-center flex-none"
              >
                <.icon name={:sparkle} class="w-3 h-3 text-violet-600 dark:text-violet-400" />
              </span>
              <div class="w-px flex-1 bg-zinc-200 dark:bg-zinc-700/60"></div>
            </div>

            <%!-- "Claude · HH:MM", vertically centered with the icon — top only. --%>
            <div :if={not turn_started_rendering?(@messages)} class="pl-7 h-5 flex items-center">
              <span class="text-sm font-semibold text-zinc-700 dark:text-zinc-200">Claude</span>
              <span
                :if={current_turn_timestamp(@messages)}
                class="ml-2 text-xs text-zinc-400 dark:text-zinc-500"
              >
                · {Calendar.strftime(current_turn_timestamp(@messages), "%H:%M")}
              </span>
            </div>

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
            <span class="text-[10px] font-medium uppercase tracking-wide text-violet-500/80 dark:text-violet-400/80">
              Queued · sends when the agent finishes
            </span>
            <button
              type="button"
              phx-click="clear_pending"
              phx-value-id={@agent.id}
              class="focus-ring text-[10px] text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300"
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
              class="focus-ring flex-1 min-w-0 text-left truncate text-xs text-zinc-600 dark:text-zinc-300"
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
          class="flex items-center gap-1.5 text-[11px] text-zinc-400 dark:text-zinc-500"
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
          <p id="send-status" class="hidden mt-1.5 text-xs text-red-500 dark:text-red-400"></p>
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
          class="text-xs text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors"
        >
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
            <input
              type="text"
              name="service"
              value={@log_service || ""}
              placeholder="Filter service..."
              class="text-xs rounded border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-2 py-1 w-28
                     focus:outline-none focus:ring-1 focus:ring-violet-500/30"
            />
          </form>
        </div>
        <pre class="flex-1 px-4 py-3 text-xs font-mono overflow-auto whitespace-pre-wrap bg-zinc-100 dark:bg-zinc-950 text-zinc-800 dark:text-green-400 min-h-[200px]">{@logs}</pre>
      </div>
    </div>
    """
  end
end
