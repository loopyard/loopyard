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
    only: [context_panel: 1, context_sections: 1]

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
  defp workspace_crumbs(assigns) do
    label = Loopyard.Source.display_name(assigns.workspace_entry)
    label = if label == "", do: assigns.workspace.name, else: label

    on_overview? = assigns[:live_action] == :index
    last_path = if on_overview?, do: nil, else: assigns.base_path

    crumbs = [{"Loopyard", "/"}]

    crumbs =
      if assigns.project do
        crumbs ++ [{assigns.project.name, "/projects/#{assigns.project.id}"}]
      else
        crumbs
      end

    crumbs ++ [{label, last_path}]
  end

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

    crumbs = workspace_crumbs(assigns)

    assigns =
      assigns
      |> assign(:back_kind, back_kind)
      |> assign(:back_target, back_target)
      |> assign(:back_label, back_label)
      |> assign(:crumbs, crumbs)
      |> assign(:host_exposed, Loopyard.HostExposer.exposed?())

    # Delegate to the ONE canonical app header (same component every page uses),
    # so the top nav — breadcrumbs, Remote, the workstation switcher, System — is
    # identical app-wide. The only workspace-specific bit is the mobile back
    # button, injected via the header's `back` slot.
    ~H"""
    <LoopyardWeb.Components.AppHeader.header
      breadcrumbs={@crumbs}
      iex_session={@iex_session}
      current_path={@base_path}
      host_exposed={@host_exposed}
    >
      <:back>
        <.link
          :if={@back_kind == :patch}
          patch={@back_target}
          class="md:hidden -ml-1 inline-flex items-center gap-1 px-2 py-1 rounded-md text-base font-medium text-violet-600 dark:text-violet-400 hover:bg-violet-50 dark:hover:bg-violet-500/10 active:bg-violet-100 dark:active:bg-violet-500/20 transition-colors flex-none min-w-0"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5 flex-none">
            <path
              fill-rule="evenodd"
              d="M17 10a.75.75 0 0 1-.75.75H5.612l4.158 3.96a.75.75 0 1 1-1.04 1.08l-5.5-5.25a.75.75 0 0 1 0-1.08l5.5-5.25a.75.75 0 1 1 1.04 1.08L5.612 9.25H16.25A.75.75 0 0 1 17 10Z"
              clip-rule="evenodd"
            />
          </svg>
          <span class="truncate">{@back_label}</span>
        </.link>
        <.link
          :if={@back_kind == :navigate}
          navigate={@back_target}
          class="md:hidden -ml-1 inline-flex items-center gap-1 px-2 py-1 rounded-md text-base font-medium text-violet-600 dark:text-violet-400 hover:bg-violet-50 dark:hover:bg-violet-500/10 active:bg-violet-100 dark:active:bg-violet-500/20 transition-colors flex-none min-w-0"
        >
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5 flex-none">
            <path
              fill-rule="evenodd"
              d="M17 10a.75.75 0 0 1-.75.75H5.612l4.158 3.96a.75.75 0 1 1-1.04 1.08l-5.5-5.25a.75.75 0 0 1 0-1.08l5.5-5.25a.75.75 0 1 1 1.04 1.08L5.612 9.25H16.25A.75.75 0 0 1 17 10Z"
              clip-rule="evenodd"
            />
          </svg>
          <span class="truncate">{@back_label}</span>
        </.link>
      </:back>
    </LoopyardWeb.Components.AppHeader.header>
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
          <.detail_level_control level={@detail_level} />
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
            <.control_btn
              :if={agent_display_status(@agent) in [:ready, :thinking]}
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
      class="hidden sm:inline-flex items-center rounded-lg bg-zinc-100 dark:bg-zinc-800 p-0.5"
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
          "px-2 py-0.5 text-[11px] font-medium rounded-md transition-colors",
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

    ~H"""
    <div class="flex-1 flex flex-col min-h-0">
      <%!-- scroll-smooth: the auto-tail (ScrollBottom hook nudges scrollTop as the
           agent streams) animates instead of jumping, so following the thinking
           glides. Pure CSS — honors prefers-reduced-motion automatically. --%>
      <div id="messages" class="flex-1 overflow-y-auto flex flex-col px-4 md:px-6 pb-4 scroll-smooth">
        <%!-- Normal flow (NOT flex-col-reverse). The ScrollBottom hook keeps you
             pinned to the bottom on new messages and anchors on load-more; this
             is what lets `position: sticky` on the prompt band work flush on
             mobile (col-reverse broke sticky). --%>
        <div class="space-y-2">
          <p
            :if={assigns[:has_more_messages]}
            class="text-center py-2 text-xs text-zinc-400 dark:text-zinc-500"
          >
            Loading older messages...
          </p>
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
                      <div class="border-l border-zinc-200/70 dark:border-zinc-800/80 ml-3">
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
          <%!-- Live tail: the agent's in-progress work continues the SAME spine —
               streamed reasoning, streamed text, and the activity feed. We show the
               "Claude" run header from the START of the turn (it appears anyway once
               content lands, so show it immediately instead of popping in). --%>
          <div :if={
            @streaming_text != "" || (assigns[:streaming_thinking] || "") != "" ||
              (@agent.status == :thinking && not awaiting_answer?(@messages) &&
                 not awaiting_approval?(@messages) && not building?(@messages))
          }>
            <.run_header timestamp={current_turn_timestamp(@messages)} />
            <div class="border-l border-zinc-200/70 dark:border-zinc-800/80 ml-3">
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
            <%!-- The live status (word + elapsed + Stop) is the LAST thing on the
                 transcript spine — below whatever the turn has produced so far,
                 un-boxed, flowing with the conversation. It used to be a docked
                 box above the input; it now lives at the foot of the timeline. --%>
            <.live_status
              :if={@agent.status == :thinking}
              messages={@messages}
              word={@thinking_word}
              agent_id={@agent.id}
            />
            </div>
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
      <%!-- Context-window heads-up — a STATUS, not an error. A full window used to
           silently wedge the agent; now it auto-compacts at ~92%. Compacting reads
           calm (violet, like the thinking status) with "nothing's wrong" wording so
           it's never mistaken for a failure; the earlier "approaching" heads-up is a
           quiet muted line. --%>
      <div
        :if={(@agent[:context_utilization] || 0.0) >= 0.85}
        class={[
          "flex items-center gap-2 text-xs",
          if((@agent[:context_utilization] || 0.0) >= 0.92,
            do: "text-violet-600 dark:text-violet-300",
            else: "text-zinc-400 dark:text-zinc-500"
          )
        ]}
      >
        <span class="flex-none">{if (@agent[:context_utilization] || 0.0) >= 0.92, do: "🗜", else: "·"}</span>
        <span class="min-w-0">
          {if (@agent[:context_utilization] || 0.0) >= 0.92,
            do:
              "Compacting — summarizing the conversation so I can keep going. This is automatic; nothing's wrong.",
            else:
              "Context #{round((@agent[:context_utilization] || 0.0) * 100)}% full — I'll auto-compact soon to keep going."}
        </span>
      </div>
      <div id="chat-form-wrapper" phx-update="ignore">
        <form id="chat-form" phx-submit="send_message" phx-hook="ChatForm" class="flex items-end gap-2">
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

  def thinking_indicator(assigns) do
    # Live activity feed: every tool action since the last human turn, in
    # order, the most recent one still running (⟳) and the rest done (✓).
    # These are the SAME tool messages the chat would render inline — while
    # the agent is working we surface them here as a pinned, rolling feed
    # instead (chat_panel suppresses the inline rows for the active turn),
    # so you can watch it work without the list scrolling away.
    activity = current_turn_activity(assigns.messages)

    assigns =
      assigns
      |> assign(:activity, activity)
      |> assign(:turn_since, turn_started_unix_ms(assigns.messages))
      |> assign(:stall_hint, retry_hint(assigns.messages))

    # No bubble, no avatar — the live work flows on the transcript spine like
    # everything else the agent does, just bigger: this IS "the computer
    # thinking", so give it room. The chat_panel wraps it in the run-spine.
    ~H"""
    <%!-- Live tool feed only. The status header (word + elapsed + Stop) is
         docked at the bottom in the Reasoning Bar so it never scrolls off the
         top, no matter how long the work runs. --%>
    <div :if={@activity != [] || @stall_hint} class="pl-7 py-1.5">
      <ul :if={@activity != []} class="space-y-1.5">
        <li :for={a <- @activity} class="flex items-start gap-2 text-sm leading-relaxed">
          <span class={[
            "flex-none w-3.5 text-center mt-0.5",
            a.active && "text-violet-500 animate-pulse",
            !a.active && "text-emerald-500/70"
          ]}>
            {if a.active, do: "▸", else: "✓"}
          </span>
          <span class={[
            "min-w-0 break-words font-mono",
            a.active && "text-zinc-700 dark:text-zinc-200",
            !a.active && "text-zinc-400 dark:text-zinc-500"
          ]}>
            {a.summary}
          </span>
        </li>
      </ul>
      <p
        :if={@stall_hint}
        class="mt-3 flex items-start gap-2 text-sm leading-relaxed text-amber-600 dark:text-amber-400"
      >
        <span class="flex-none">⚠</span>
        <span class="min-w-0">{@stall_hint}</span>
      </p>
    </div>
    """
  end

  @doc """
  The live status line — animated dots + status word + elapsed + a compact Stop,
  rendered UN-BOXED at the foot of the transcript spine (below everything the turn
  has produced so far, above the composer). No card, no background: it reads as the
  conversation's live tail, not a docked widget.
  """
  attr :messages, :list, required: true
  attr :word, :string, required: true
  attr :agent_id, :string, required: true

  def live_status(assigns) do
    # `word` is nil until a tool event fires (e.g. during prefill/compaction), which
    # rendered a bare "…". Default to "Thinking" so the bar always reads as something.
    assigns =
      assigns
      |> assign(:turn_since, turn_started_unix_ms(assigns.messages))
      |> assign(:word, if(assigns.word in [nil, ""], do: "Thinking", else: assigns.word))

    ~H"""
    <%!-- Full-width live bar at the BOTTOM of the timeline. Its content sits on the
         SAME left gutter (pl-7) as the activity rows above, so the dots line up
         under the ✓/$ column. Squared + borderless on the LEFT so it runs flush
         into the timeline (reads as part of it), rounded on the RIGHT. --%>
    <div class="mt-2">
      <div class="flex items-center gap-3 rounded-r-xl rounded-l-none border border-l-0 border-violet-200/70 dark:border-violet-500/20 bg-violet-50 dark:bg-violet-500/10 pl-7 pr-3 py-2.5">
        <div class="flex gap-1.5 flex-none" aria-hidden="true">
          <div class="w-2 h-2 rounded-full bg-violet-400 animate-bounce" style="animation-delay: 0ms">
          </div>
          <div class="w-2 h-2 rounded-full bg-violet-400 animate-bounce" style="animation-delay: 150ms">
          </div>
          <div class="w-2 h-2 rounded-full bg-violet-400 animate-bounce" style="animation-delay: 300ms">
          </div>
        </div>
        <span class="text-sm font-semibold text-violet-700 dark:text-violet-200 flex-none">{@word}…</span>
        <span
          :if={@turn_since}
          id="turn-elapsed"
          phx-hook="Elapsed"
          phx-update="ignore"
          data-since={@turn_since}
          class="text-xs text-violet-500/70 dark:text-violet-300/50 flex-none tabular-nums"
        >
        </span>
        <div class="flex-1 min-w-0"></div>
        <button
          type="button"
          phx-click="interrupt_agent"
          phx-value-id={@agent_id}
          class="focus-ring inline-flex items-center gap-2 rounded-lg px-3 py-1.5 text-sm font-medium text-zinc-600 dark:text-zinc-300 hover:text-red-600 dark:hover:text-red-400 hover:bg-red-500/10 active:bg-red-500/20 transition-colors flex-none"
        >
          <span class="w-2.5 h-2.5 rounded-[3px] bg-red-500"></span> Stop
        </button>
      </div>
    </div>
    """
  end

  @doc """
  The Reasoning Bar — the live status, docked just above the input so it's ALWAYS
  visible (the transcript feed scrolls off; this never does). Animated dots +
  status word + elapsed + the current action + a compact Stop. Reasoning "comes
  out of" the composer: it sits fused above the message box, and you can keep
  queuing while it runs (the queue renders right above it).
  """
  attr :messages, :list, required: true
  attr :word, :string, required: true
  attr :agent_id, :string, required: true

  def reasoning_bar(assigns) do
    activity = current_turn_activity(assigns.messages)
    current = Enum.find(activity, & &1.active) || List.last(activity)

    assigns =
      assigns
      |> assign(:turn_since, turn_started_unix_ms(assigns.messages))
      |> assign(:current_action, current && current.summary)

    ~H"""
    <div class="flex items-center gap-2.5 rounded-xl bg-violet-50 dark:bg-violet-500/10 border border-violet-200/70 dark:border-violet-500/20 px-3.5 py-2">
      <div class="flex gap-1 flex-none" aria-hidden="true">
        <div class="w-1.5 h-1.5 rounded-full bg-violet-400 animate-bounce" style="animation-delay: 0ms">
        </div>
        <div class="w-1.5 h-1.5 rounded-full bg-violet-400 animate-bounce" style="animation-delay: 150ms">
        </div>
        <div class="w-1.5 h-1.5 rounded-full bg-violet-400 animate-bounce" style="animation-delay: 300ms">
        </div>
      </div>
      <span class="text-sm font-medium text-violet-600 dark:text-violet-300 flex-none">{@word}…</span>
      <span
        :if={@turn_since}
        id="turn-elapsed"
        phx-hook="Elapsed"
        phx-update="ignore"
        data-since={@turn_since}
        class="text-xs text-zinc-400 dark:text-zinc-500 flex-none tabular-nums"
      >
      </span>
      <span
        :if={@current_action}
        class="hidden sm:block text-xs text-zinc-500 dark:text-zinc-400 truncate min-w-0"
      >
        · {@current_action}
      </span>
      <div class="flex-1"></div>
      <button
        type="button"
        phx-click="interrupt_agent"
        phx-value-id={@agent_id}
        class="focus-ring inline-flex items-center gap-1.5 rounded-lg px-2.5 py-1 text-xs font-medium text-zinc-600 dark:text-zinc-300 hover:text-red-600 dark:hover:text-red-400 hover:bg-red-500/10 transition-colors flex-none"
      >
        <span class="w-2 h-2 rounded-[2px] bg-red-500"></span> Stop
      </button>
    </div>
    """
  end

  # If the agent's last actual response was an upstream API failure (overload,
  # 5xx, timeout), it's almost certainly retrying it right now — say so, so a
  # long-running "thinking…" reads as "Anthropic is busy" not "wedged".
  @api_error_re ~r/\b(529|503|502|500|overloaded|api error|internal server error|service unavailable|upstream)\b/i

  defp retry_hint(messages) do
    last_response =
      messages
      |> Enum.reverse()
      |> Enum.find(fn m -> m.role in [:assistant, :error] and is_binary(m[:content]) and m.content != "" end)

    case last_response do
      %{content: c} ->
        cond do
          c =~ ~r/\b(529|overloaded)\b/i ->
            "Claude's servers are overloaded — retrying this turn. Can take a minute; press Stop and resend if it doesn't recover."

          c =~ @api_error_re ->
            "Last response hit a temporary server error — retrying. Press Stop and resend if it doesn't recover."

          true ->
            nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Tool actions for the in-progress turn (since the last human message),
  oldest→newest, each tagged `active: true` (the latest — still running) or
  `false` (done). The same set chat_panel suppresses inline, so the feed and
  the scrollback never double-list.
  """
  def current_turn_activity(messages) do
    tools = current_turn_tools(messages)
    last = length(tools) - 1

    tools
    |> Enum.with_index()
    |> Enum.map(fn {m, i} ->
      %{
        summary: LoopyardWeb.Components.ToolSummary.summarize(m.tool, m.input || %{}),
        active: i == last
      }
    end)
  end

  # Unix-ms of the last human message — the live elapsed timer counts up from
  # here, so even a long silent prefill (huge context, no tokens yet) shows a
  # ticking "it's alive" signal. nil (no timer) if the turn start isn't on the
  # current page or carries no timestamp.
  defp turn_started_unix_ms(messages) do
    case Enum.reverse(messages) |> Enum.find(&(&1.role == :user)) do
      %{timestamp: %DateTime{} = ts} -> DateTime.to_unix(ts, :millisecond)
      _ -> nil
    end
  end

  # The current turn's start time (the last human message) — used for the live
  # "Claude · HH:MM" run header so it reads the same as a finished run.
  defp current_turn_timestamp(messages) do
    case Enum.reverse(messages) |> Enum.find(&(&1.role == :user)) do
      %{timestamp: %DateTime{} = ts} -> ts
      _ -> nil
    end
  end

  defp current_turn_tools(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(&(&1.role != :user))
    |> Enum.reverse()
    |> Enum.filter(&(&1.role == :tool and not own_surface_tool?(&1[:tool])))
  end

  # Tools that render their OWN prominent surface — exec/docker_compose as a
  # console box, and ask_user/request_secret/propose_* as an interactive card — so
  # they don't ALSO belong in the compact activity feed, which would double-show
  # them (the command/card a second time).
  @own_surface_tools ~w(
    exec docker_compose ask_user request_secret
    propose_fork propose_integrate propose_delete_workspace
  )
  defp own_surface_tool?(tool) when is_binary(tool),
    do: Enum.any?(@own_surface_tools, &String.ends_with?(tool, &1))

  defp own_surface_tool?(_), do: false

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
