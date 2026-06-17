defmodule LoopyardWeb.Live.WorkspaceLive.Components.Chat do
  @moduledoc "Chat panel components: agent_view, agent_header, chat_panel, thinking_indicator, container_panel."
  use Phoenix.Component

  import LoopyardWeb.Components.Common, only: [dot: 1, control_btn: 1]
  import LoopyardWeb.Components.Sidebar, only: [status_dot: 1, agent_display_status: 1]
  import LoopyardWeb.Components.Breadcrumbs, only: [breadcrumbs: 1]

  import LoopyardWeb.Live.WorkspaceLive.Messages,
    only: [chat_msg: 1, streaming_bubble: 1, streaming_thinking: 1]

  import LoopyardWeb.Live.WorkspaceLive.Components.Formatters, only: [time_ago: 1]
  import LoopyardWeb.Live.WorkspaceLive.Components.ContextPanel, only: [context_panel: 1]

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
    mobile_crumbs = Enum.take(crumbs, -1)

    assigns =
      assigns
      |> assign(:back_kind, back_kind)
      |> assign(:back_target, back_target)
      |> assign(:back_label, back_label)
      |> assign(:crumbs, crumbs)
      |> assign(:mobile_crumbs, mobile_crumbs)
      |> assign(:host_exposed, Loopyard.HostExposer.exposed?())

    ~H"""
    <header class="flex-none h-14 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center justify-between px-4 md:px-5">
      <div class="flex items-center gap-3 min-w-0">
        <.link
          :if={@back_kind == :patch}
          patch={@back_target}
          class="md:hidden -ml-1 inline-flex items-center gap-1 px-2 py-1 rounded-md text-base font-medium text-violet-600 dark:text-violet-400 hover:bg-violet-50 dark:hover:bg-violet-500/10 active:bg-violet-100 dark:active:bg-violet-500/20 transition-colors flex-none min-w-0"
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
          <span class="truncate">{@back_label}</span>
        </.link>
        <.link
          :if={@back_kind == :navigate}
          navigate={@back_target}
          class="md:hidden -ml-1 inline-flex items-center gap-1 px-2 py-1 rounded-md text-base font-medium text-violet-600 dark:text-violet-400 hover:bg-violet-50 dark:hover:bg-violet-500/10 active:bg-violet-100 dark:active:bg-violet-500/20 transition-colors flex-none min-w-0"
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
          <span class="truncate">{@back_label}</span>
        </.link>
        <.breadcrumbs crumbs={@crumbs} class="hidden md:flex" />
        <.breadcrumbs crumbs={@mobile_crumbs} class="md:hidden" />
        <LoopyardWeb.Components.AppHeader.iex_indicator
          :if={@iex_session.level}
          session={@iex_session}
        />
      </div>
      <div class="flex items-center gap-2 flex-none hidden md:flex">
        <.link
          navigate={Path.join("/remote", @base_path)}
          aria-label={
            if @host_exposed,
              do: "Remote access — exposed. Open connect page.",
              else: "Remote access — private. Open connect page."
          }
          class={[
            "focus-ring inline-flex items-center gap-1.5 px-2 py-1 text-sm font-medium transition-colors rounded",
            if(@host_exposed,
              do: "text-emerald-600 dark:text-emerald-400 hover:text-emerald-500",
              else: "text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-100"
            )
          ]}
        >
          <span
            :if={@host_exposed}
            class="w-1.5 h-1.5 rounded-full bg-emerald-500 flex-none"
            aria-hidden="true"
          >
          </span>
          Remote
        </.link>
        <.link
          navigate="/system"
          class="focus-ring inline-flex items-center px-2 py-1 text-sm font-medium text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-100 transition-colors rounded"
        >
          System
        </.link>
      </div>
    </header>
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
        />
        <.container_panel
          :if={@tab == :container}
          env={@container_env}
          logs={@container_logs}
          log_service={@container_log_service}
          has_container={@has_container}
        />
      </div>
      <%!-- Agent context lives in the right rail on desktop. On mobile that
           rail is hidden, so the "Info" link (:context_panel) shows the same
           context full-screen here. --%>
      <div :if={@tab == :context_panel} class="flex-1 lg:hidden">
        <.context_panel
          agent={@selected_agent}
          has_container={@has_container}
          container_env={@container_env}
          container_logs={@container_logs}
          editing_name={@editing_name}
          mobile={true}
        />
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
        <div class="flex items-center gap-1 md:gap-2 flex-none">
          <%!--
            Mobile-only navigation into the Agent Context pane. On lg+
            the pane is always visible in the right rail, so we hide
            the link. Mirrors the "Menu" back-link on the left that
            returns to the sidebar — sidebar → chat → context.
          --%>
          <.link
            patch={"#{@base_path}/agents/#{@agent.id}/context"}
            class="lg:hidden text-xs font-medium text-zinc-500 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-700 rounded-md px-2 py-1"
            aria-label="Agent context"
          >
            Info
          </.link>
          <%!-- Two primary actions, mutually exclusive. Stop shows while
               the agent is Ready or Thinking; Start shows while it's
               Sleeping or Crashed. (No "Restart CLI" — Stop + Start
               gives the same effect by replaying from the log.)
               Matches the service-control button style for visual
               consistency across the workspace. --%>
          <.control_btn
            :if={agent_display_status(@agent) in [:ready, :thinking]}
            phx-click="stop_agent"
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

  # --- Chat Panel ---

  def chat_panel(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col min-h-0">
      <div id="messages" class="flex-1 overflow-y-auto flex flex-col-reverse px-4 md:px-6 py-4">
        <%!-- flex-col-reverse: browser anchors scroll to the bottom naturally.
             scrollTop=0 IS the bottom. No JS timing hacks needed.
             Content is rendered inside a nested div in normal order. --%>
        <div class="space-y-1">
          <p
            :if={assigns[:has_more_messages]}
            class="text-center py-2 text-xs text-zinc-400 dark:text-zinc-500"
          >
            Loading older messages...
          </p>
          <div :for={{msg, idx} <- Enum.with_index(@messages)}>
            <.chat_msg
              msg={msg}
              idx={idx}
              messages={@messages}
              agent_id={@agent.id}
              workspace_id={@workspace_id}
              host={@host}
            />
          </div>
          <.streaming_thinking
            :if={assigns[:streaming_thinking] != "" && assigns[:streaming_thinking] != nil}
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
        </div>
      </div>
      <div
        id="chat-form-wrapper"
        phx-update="ignore"
        class="flex-none border-t border-zinc-200 dark:border-zinc-700/80 p-3 md:p-4"
      >
        <form id="chat-form" phx-submit="send_message" phx-hook="ChatForm" class="flex gap-2">
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
            class="rounded-xl bg-violet-600 hover:bg-violet-700 px-4 py-2.5 text-base font-medium text-white transition-colors flex-none"
          >
            Send
          </button>
        </form>
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
    last_tool =
      assigns.messages
      |> Enum.reverse()
      |> Enum.find(&(&1.role == :tool))

    last_action =
      if last_tool do
        LoopyardWeb.Components.ToolSummary.summarize(last_tool.tool, last_tool.input)
      else
        nil
      end

    assigns = assign(assigns, :last_action, last_action)

    ~H"""
    <div class="flex gap-3 mt-3">
      <div class="flex-none w-7 h-7 rounded-full bg-violet-100 dark:bg-violet-900/40 flex items-center justify-center mt-0.5">
        <span class="text-xs font-bold text-violet-600 dark:text-violet-400">C</span>
      </div>
      <div class="rounded-2xl rounded-tl-sm bg-zinc-100 dark:bg-zinc-800 px-4 py-3">
        <div class="flex items-center gap-2">
          <div class="flex gap-1 flex-none">
            <div
              class="w-1.5 h-1.5 rounded-full bg-violet-400 animate-bounce"
              style="animation-delay: 0ms"
            >
            </div>
            <div
              class="w-1.5 h-1.5 rounded-full bg-violet-400 animate-bounce"
              style="animation-delay: 150ms"
            >
            </div>
            <div
              class="w-1.5 h-1.5 rounded-full bg-violet-400 animate-bounce"
              style="animation-delay: 300ms"
            >
            </div>
          </div>
          <span class="text-base text-violet-500 dark:text-violet-400 flex-none">{@word}...</span>
        </div>
        <p :if={@last_action} class="text-xs text-zinc-500 dark:text-zinc-400 mt-1 truncate">
          {@last_action}
        </p>
      </div>
    </div>
    """
  end

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
