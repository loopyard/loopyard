defmodule LoopyardWeb.OperatorLive do
  @moduledoc """
  `/operator` — the operator agent's own chat, standalone (no workspace chrome).
  The operator is an in-container ACP agent (its own workstation container) with
  no workspace/project, so it can't render through the workspace view — it gets
  its own focused screen:
  a header + the shared `chat_panel`. Created on first visit
  (`Loopyard.Operator.ensure_agent/0`).

  **Same rendering mechanisms as the workspace chat.** We deliberately reuse the
  extracted handlers (`AgentEvents.handle_message/handle_text_delta/
  handle_status_changed`) and the shared `StreamBuffer` rather than re-fetching
  the whole transcript on every event. That means: incremental append + dedup on
  new messages, live token streaming, and streamed tool/exec output — the exact
  efficient path the workspace built. To use those handlers we adopt their assign
  contract (`selected_id`, `agents`, `selected_agent`, `messages`,
  `streaming_text`, `streaming_thinking`, `stream_buffer`, …), flattening the
  operator's single agent into the same shape as a one-agent workspace.
  """
  use LoopyardWeb, :live_view

  alias Loopyard.{ChatAgent, Operator, StreamBuffer}
  alias Loopyard.Events
  alias LoopyardWeb.Components.Nav
  alias LoopyardWeb.Live.WorkspaceLive.AgentEvents
  import LoopyardWeb.Components.Breadcrumbs, only: [breadcrumbs: 1]
  import LoopyardWeb.Live.WorkspaceLive.Components.Chat, only: [chat_panel: 1]

  # Answerable consent cards rendered inline in the "for you" rail — same broker +
  # ConsentUI hook as the chat, so a question is answered right there.
  import LoopyardWeb.Live.WorkspaceLive.Messages.Cards, only: [question_card: 1, secret_card: 1]

  @aural_channel "activity"
  @rail_tick_ms 3_000
  # The bed roster — mirrors SoundLive so the rail player and /sound agree.
  @tracks [
    {:serene, "Serene"},
    {:nocturne, "Nocturne"},
    {:cascade, "Cascade"},
    {:hum, "Hum"},
    {:pink, "Pink"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, %{agent_id: agent_id}} = Operator.ensure_agent()

    if connected?(socket) do
      Events.ChatAgentMessage.subscribe(agent_id)
      Events.ChatAgent.subscribe()
      # Operator `music` play/pause/volume commands → bridged to this client's
      # AmbientAudio engine (server-side track/status don't need this).
      Events.Aural.subscribe()
      # Keep the rail fresh: status/message events refresh it instantly; this tick
      # is the backstop that catches a cross-workspace answer or a timed-out
      # question we didn't get a direct event for (same pattern as the town hall).
      Process.send_after(self(), :refresh_rail, @rail_tick_ms)
    end

    host =
      case socket.host_uri do
        %URI{host: h} when is_binary(h) and h != "" -> h
        _ -> "localhost"
      end

    socket =
      socket
      |> assign(:agent_id, agent_id)
      # The shared chat handlers key everything off :selected_id — the operator's
      # single agent IS the selection.
      |> assign(:selected_id, agent_id)
      |> assign(:host, host)
      |> assign(:streaming_text, "")
      |> assign(:stream_md, Loopyard.Markdown.Stream.new())
      # The rail's ambient-sound player (track roster + current track).
      |> assign(:tracks, @tracks)
      |> assign(:current_track, current_track())
      |> assign(:streaming_thinking, "")
      |> assign(:stream_buffer, StreamBuffer.new())
      |> assign(:building, false)
      |> assign(:thinking_word, nil)
      |> assign(:restored_failed_prompt, nil)
      # No windowing for the operator's short chats — the whole transcript is the
      # tail. (chat_panel still reads these two.)
      |> assign(:has_more_messages, false)
      |> assign(:window_tail?, true)
      # The rail (needs-you groups + working jobs + count) computed IN the
      # LiveView and stored as real assigns, so it's part of the reactive graph —
      # NOT recomputed inside the component (which LiveView memoizes when @tree/
      # @host don't change, leaving the rail stale after an answer).
      |> refresh_rail()
      |> load_agent()
      # The shared consent surface: question + secret cards answer through the
      # SAME hook as the workspace chat, so the operator stream is never missing
      # a consent feature. No workspace → secrets scope to nil.
      |> LoopyardWeb.Live.ConsentUI.attach(secret_scope: nil)

    {:ok, socket}
  end

  # Load the agent summary + transcript into the workspace-chat assign shape:
  # `agents` is a one-element list so `AgentEvents.refresh_selected_from_agents`
  # (ETS-counter merge) finds it. Used at mount + after an approval decision (the
  # one message-*update* path with no incremental event to ride).
  defp load_agent(socket) do
    case ChatAgent.get_state(socket.assigns.agent_id) do
      %{} = st ->
        socket
        |> assign(:selected_agent, st)
        |> assign(:agents, [st])
        |> assign(:messages, st.messages)

      _ ->
        stub = %{id: socket.assigns.agent_id, status: :idle}
        socket |> assign(:selected_agent, stub) |> assign(:agents, [stub]) |> assign(:messages, [])
    end
  end

  @impl true
  def handle_event("send_message", %{"message" => message}, socket) do
    # Drop empty / whitespace-only sends so the operator never gets a blank prompt
    # (which makes it reply "your message came through empty"). Still ack so the
    # ChatForm hook clears the box.
    message = String.trim(message)
    if message != "", do: ChatAgent.send_message(socket.assigns.agent_id, message)
    {:reply, %{ok: true}, socket}
  end

  # Composer/queue controls (chat_panel emits these) — wired so no button is dead.
  def handle_event("clear_pending", _p, socket) do
    ChatAgent.clear_pending(socket.assigns.agent_id)
    {:noreply, socket}
  end

  def handle_event("remove_pending", %{"id" => id, "index" => index}, socket) do
    ChatAgent.remove_pending(id, String.to_integer(index))
    {:noreply, socket}
  end

  def handle_event("edit_pending", %{"id" => id, "index" => index}, socket) do
    index = String.to_integer(index)
    text = Enum.at(socket.assigns.selected_agent[:pending_messages] || [], index)
    ChatAgent.remove_pending(id, index)

    if is_binary(text),
      do: {:noreply, push_event(socket, "fill_input", %{text: text})},
      else: {:noreply, socket}
  end

  def handle_event("interrupt_agent", %{"id" => id}, socket) do
    ChatAgent.interrupt(id)
    {:noreply, socket}
  end

  # Approve/Deny on the approval "chat mini app" — the interactive half of the
  # create-project flow. Delivers the decision to the blocked ControlPlane tool
  # (which then fires Onboarding + spawns the workspace agent). Operator cards are
  # only create_project (no delete/navigation), so this stays simple.
  def handle_event("decide_approval", %{"approval_id" => id, "decision" => decision}, socket) do
    decision = if decision == "approve", do: :approve, else: :deny
    agent_id = socket.assigns.agent_id
    card = Enum.find(socket.assigns.messages, &(&1[:approval_id] == id))

    # Optimistic flip so the buttons don't sit unclicked while the action runs —
    # but the transient must MATCH the verb (a rename is not "Creating the branch
    # workspace"; that misleading text made a harmless rename look destructive).
    if decision == :approve and card do
      transient =
        case card[:action][:verb] do
          v when v in [:delete_workspace, :delete_project] -> :deleting
          v when v in [:rename_workspace, :rename_project] -> :renaming
          :integrate -> :integrating
          _ -> :creating
        end

      ChatAgent.update_message(agent_id, card.id, &Map.put(&1, :status, transient))
    end

    case Loopyard.Harness.Approvals.decide(id, decision) do
      :ok ->
        :ok

      {:error, :not_found} ->
        if card do
          ChatAgent.update_message(agent_id, card.id, fn m ->
            Map.merge(m, %{status: :failed, error: "this proposal expired — ask again"})
          end)
        end
    end

    # A message *field* update (not a new message) has no incremental event to
    # ride, so re-sync the transcript here. Rare (a button click), unlike the
    # streaming hot path which stays incremental.
    {:noreply, load_agent(socket)}
  end

  # Dive into a job's agent chat — re-anchor your read-position (delta → 0, so a
  # read done job retires), then navigate into that workspace's own stream.
  def handle_event("open_job", %{"ws" => ws, "project" => pid, "agent" => aid}, socket) do
    Loopyard.Operator.Jobs.mark_read(ws)
    {:noreply, push_navigate(socket, to: ~p"/projects/#{pid}/workspaces/#{ws}/agents/#{aid}")}
  end

  # Rail sound player: crossfade the bed to another track (no reconnect).
  def handle_event("pick_track", %{"track" => track}, socket) do
    Aural.Channel.pick_track(@aural_channel, String.to_existing_atom(track))
    {:noreply, assign(socket, :current_track, String.to_existing_atom(track))}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event(_evt, _params, socket), do: {:noreply, socket}

  # A workspace's mapped ports as launchable links. `port` is the HOST port (what
  # you actually navigate to — the container port is internal), matching the
  # workspace header's app-port link.
  defp workspace_ports(ws_id, host) do
    Loopyard.PortRegistry.list_for_workspace(ws_id)
    |> Enum.map(fn e -> %{port: e[:host_port], url: "http://#{host}:#{e[:host_port]}"} end)
    |> Enum.reject(&is_nil(&1.port))
    |> Enum.sort_by(& &1.port)
  rescue
    _ -> []
  end

  defp current_track do
    Aural.Channel.state(@aural_channel).track
  rescue
    _ -> :serene
  catch
    _, _ -> :serene
  end

  # Compute the rail's data IN the LiveView so it's bound to the reactive assign
  # graph. The operator's OWN blocking questions live in the chat (your direct
  # conversation) — excluded here so they don't double up in the rail.
  defp refresh_rail(socket) do
    host = socket.assigns.host
    op = socket.assigns.agent_id
    tree = Loopyard.WorkspaceTree.global(host)
    line = Loopyard.Attention.line(host)

    groups =
      line
      |> Enum.reject(&(&1.agent_id == op))
      |> Enum.group_by(& &1.workspace_id)
      |> Enum.map(fn {_ws, items} ->
        first = hd(items)

        %{
          name: first.workspace_name || "Operator",
          project: first.project_name,
          path: first.path,
          items: items
        }
      end)
      |> Enum.sort_by(&length(&1.items), :desc)

    watched = Loopyard.Operator.Digest.watches() |> MapSet.new(& &1.ws_id)

    jobs =
      tree
      |> Loopyard.Operator.Queue.items()
      |> Enum.map(fn j ->
        j
        |> Map.put(:watching?, MapSet.member?(watched, j.id))
        # Mapped ports as launchable links — the operator's viewer is on the host,
        # so a workspace's dev server is reachable at host:host_port.
        |> Map.put(:ports, workspace_ports(j.id, host))
      end)

    socket
    |> assign(:tree, tree)
    |> assign(:attention_groups, groups)
    |> assign(:rail_jobs, jobs)
    # Header count = ALL blocking items (matches /queue, which the button opens);
    # the rail groups exclude the operator's own (those show in the chat).
    |> assign(:needs_you_count, length(line))
  end

  # --- Message + streaming events: delegate to the SAME handlers the workspace
  # chat uses, so the operator gets incremental append + live streaming. ---

  @impl true
  def handle_info(%Events.ChatAgentMessage.Message{} = e, socket),
    do: AgentEvents.handle_message(e, socket)

  # Card status resolutions (approval → :renamed / :deleted / :approved / progress)
  # ride MessageUpdated. Without this the operator's cards freeze at their
  # optimistic status and never show the outcome (the "stuck Creating…" bug).
  def handle_info(%Events.ChatAgentMessage.MessageUpdated{} = e, socket) do
    {:noreply, socket} = AgentEvents.on_message_updated(e, socket)
    # A message update can resolve a question → refresh the rail so the answered
    # card doesn't sit there stale (the "not bound to LV" bug).
    {:noreply, refresh_rail(socket)}
  end

  def handle_info(%Events.ChatAgentMessage.TextDelta{} = e, socket),
    do: AgentEvents.handle_text_delta(e, socket)

  # Ambient play/pause/volume command from the operator's `music` tool → push to
  # this client's AmbientAudio engine (which applies it; the sound pill reflects).
  def handle_info(%Events.Aural.Command{action: action, value: value}, socket),
    do: {:noreply, push_event(socket, "aural_command", %{action: to_string(action), value: value})}

  # Streamed model reasoning → the thinking bubble.
  def handle_info(
        %Events.ChatAgentMessage.StreamOutput{agent_id: id, data: data, title: "__thinking__"},
        socket
      )
      when id == socket.assigns.selected_id do
    {:noreply,
     socket
     |> assign(:streaming_thinking, (socket.assigns[:streaming_thinking] || "") <> data)
     |> push_event("scroll_bottom", %{})}
  end

  # Streamed tool/exec output → upsert one build message via the shared StreamBuffer.
  def handle_info(
        %Events.ChatAgentMessage.StreamOutput{agent_id: id, data: data, title: title, msg_id: msg_id},
        socket
      )
      when id == socket.assigns.selected_id do
    stream_buffer = StreamBuffer.append(socket.assigns.stream_buffer, data, title: title, msg_id: msg_id)
    messages = StreamBuffer.upsert_message(stream_buffer, socket.assigns.messages)

    {:noreply,
     socket
     |> assign(:messages, messages)
     |> assign(:stream_buffer, stream_buffer)
     |> assign(:building, true)
     |> push_event("scroll_bottom", %{})}
  end

  def handle_info(%Events.ChatAgentMessage.StreamOutput{}, socket), do: {:noreply, socket}

  def handle_info(%Events.ChatAgent.StatusChanged{} = e, socket) do
    {:noreply, socket} = AgentEvents.handle_status_changed(e, socket)

    # The operator's OWN status drives the ambient bed — it swells while the
    # operator works, settles when idle. Best-effort; sound never blocks the page.
    if e.id == socket.assigns.agent_id, do: drive_sound(e.status)

    # Any agent's status change can move the board AND change what's blocking.
    {:noreply, refresh_rail(socket)}
  end

  # Backstop tick: catches a cross-workspace answer / timed-out question we got no
  # direct event for. Cheap (ETS reads); keeps the rail honest.
  def handle_info(:refresh_rail, socket) do
    Process.send_after(self(), :refresh_rail, @rail_tick_ms)
    {:noreply, refresh_rail(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Operator activity → ambient loudness (Aural continuous level, 0..1).
  defp drive_sound(status) do
    level = if status in [:thinking, :backoff, :compacting], do: 0.7, else: 0.12
    Aural.Channel.set_activity("activity", level)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="operator-page"
      phx-hook="ScrollBottom"
      class="h-screen flex flex-col bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100 safe-area-x"
    >
      <Nav.bar height="h-14" gap="gap-3">
        <.breadcrumbs crumbs={[{"Loopyard", "/"}, {"Operator", nil}]} />
        <:actions>
          <%!-- "Needs you" → the town hall (/queue): the stack of blocking
               questions/secrets/approvals to go through, answerable inline. --%>
          <.link
            navigate={~p"/queue"}
            aria-label="Needs you — the town hall"
            class="focus-ring inline-flex items-center gap-1.5 rounded-full border border-zinc-200 dark:border-zinc-700 px-3 h-9 text-sm font-medium text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
          >
            Needs you
            <span
              :if={@needs_you_count > 0}
              class="inline-flex items-center justify-center min-w-[1.25rem] h-5 px-1 rounded-full bg-amber-500 text-white text-xs font-semibold"
            >
              {@needs_you_count}
            </span>
          </.link>
          <%!-- Sound moved to a proper player docked at the bottom of the rail. --%>
        </:actions>
      </Nav.bar>

      <div class="flex-1 min-h-0 flex">
        <%!-- Chat is PRIMARY — mostly you just talk to the operator. --%>
        <div class="flex-1 min-w-0 flex flex-col min-h-0">
          <.chat_panel
            messages={@messages}
            streaming_text={@streaming_text}
            streaming_thinking={@streaming_thinking}
            agent={@selected_agent}
            workspace_id={nil}
            host={@host}
            thinking_word={@thinking_word || "Thinking"}
            has_more_messages={@has_more_messages}
            window_tail?={@window_tail?}
            detail_level={:chat}
          />
        </div>
        <%!-- Desktop (lg+): the "for you" rail — co-equal with the chat. Leads
             with NEEDS YOU (blocking questions/approvals, grouped by workspace,
             answered inline) then WORKING (dispatched jobs + progress). The
             operator curates this; the chat is where you talk about it. --%>
        <aside class="hidden lg:flex lg:w-[26rem] xl:w-[32rem] flex-none flex-col border-l border-zinc-200 dark:border-zinc-800 bg-zinc-50/60 dark:bg-zinc-900/40">
          <div class="flex-1 min-h-0 overflow-y-auto">
            <.for_you_rail groups={@attention_groups} jobs={@rail_jobs} />
          </div>
          <.sound_player id="rail-sound" tracks={@tracks} current_track={@current_track} />
        </aside>
      </div>
    </div>
    """
  end

  # The "for you" rail — PURE render of assigns computed in refresh_rail/1 (bound
  # to the reactive graph, so it updates when a question is answered). NEEDS YOU
  # (blocking items, grouped by workspace, answered inline via the ConsentUI hook)
  # + WORKING (dispatched jobs, live state + delta).
  attr :groups, :list, required: true
  attr :jobs, :list, required: true

  defp for_you_rail(assigns) do
    ~H"""
    <div class="flex flex-col">
      <%!-- Blocking items (action required), grouped by workspace — no header,
           the groups speak for themselves and lead the rail. --%>
      <section :if={@groups != []} class="p-3 space-y-3">
        <div :for={g <- @groups} class="space-y-1.5">
          <div class="flex items-baseline gap-1.5 px-1">
            <span class="text-sm font-semibold text-zinc-700 dark:text-zinc-200 truncate">
              {g.name}
            </span>
            <span :if={g.project} class="text-xs text-zinc-400 dark:text-zinc-500 truncate">
              {g.project}
            </span>
            <span class="ml-auto flex-none text-xs text-zinc-400 dark:text-zinc-500">
              {length(g.items)} waiting
            </span>
          </div>

          <div :for={item <- g.items}>
            <.question_card :if={item.kind == :question and item.msg} msg={item.msg} />
            <.secret_card :if={item.kind == :secret and item.msg} msg={item.msg} />
            <.link
              :if={item.kind == :approval or (item.kind != :question and is_nil(item.msg))}
              navigate={item.path}
              class="focus-ring flex items-center gap-2 rounded-lg px-2.5 py-2 bg-white dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-800 hover:border-violet-300 dark:hover:border-violet-500/40"
            >
              <span class="flex-1 min-w-0 truncate text-sm text-zinc-700 dark:text-zinc-200">
                {item.label}
              </span>
              <span class="flex-none text-xs font-medium text-violet-600 dark:text-violet-400">
                open →
              </span>
            </.link>
          </div>
        </div>
      </section>

      <%!-- WORKING — ambient progress of what you dispatched --%>
      <section class="p-3 space-y-1.5 border-t border-zinc-200 dark:border-zinc-800">
        <div class="text-xs font-semibold uppercase tracking-wide text-zinc-400 dark:text-zinc-500 px-1 pb-1">
          Working
        </div>
        <p :if={@jobs == []} class="px-1 text-sm text-zinc-500 dark:text-zinc-400">
          Nothing dispatched yet.
        </p>
        <div
          :for={i <- @jobs}
          phx-click="open_job"
          phx-value-ws={i.id}
          phx-value-project={i.project_id}
          phx-value-agent={i.agent_id}
          class="rounded-lg px-2.5 py-2 border border-transparent hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors cursor-pointer"
        >
          <div class="flex items-center gap-2">
            <span class={["flex-none w-1.5 h-1.5 rounded-full", state_dot(i.state)]} />
            <span class="flex-1 min-w-0 truncate text-sm font-medium text-zinc-700 dark:text-zinc-200">
              {i.project_name} · {i.workspace_name}
            </span>
            <span
              :if={i.watching?}
              title="Watching — you'll be told when this finishes"
              class="flex-none text-xs text-amber-600 dark:text-amber-400"
            >
              🔔
            </span>
            <span
              :if={i.delta > 0}
              class="flex-none text-xs font-semibold text-violet-600 dark:text-violet-400"
            >
              {i.delta} new
            </span>
          </div>
          <div class="mt-0.5 pl-3.5 text-xs truncate">
            <span class={state_text(i.state)}>{state_label(i.state)}</span><span
              :if={i.needs not in ["", state_label(i.state)]}
              class="text-zinc-500 dark:text-zinc-400"
            > · {i.needs}</span>
          </div>
          <%!-- Launchable ports — same style as the workspace header's app-port
               link (font-mono emerald `:host_port ↗`). stopPropagation keeps the
               click off the card's open_job dive-in. --%>
          <div :if={i.ports != []} class="mt-0.5 pl-3.5 flex flex-wrap gap-2">
            <a
              :for={p <- i.ports}
              href={p.url}
              target="_blank"
              rel="noopener"
              onclick="event.stopPropagation()"
              aria-label={"Open app on port #{p.port}"}
              class="focus-ring inline-flex items-center gap-0.5 rounded px-1 font-mono text-sm text-emerald-600 dark:text-emerald-400 hover:bg-emerald-500/10 active:bg-emerald-500/20 transition-colors"
            >
              :{p.port} <span class="text-xs opacity-70">↗</span>
            </a>
          </div>
        </div>
      </section>
    </div>
    """
  end

  # Docked ambient-sound player. Reuses the SoundPill hook (drives the root-layout
  # AmbientAudio engine over window events) for play/pause + volume; the track
  # pills crossfade the bed via `pick_track` (server). Bigger than the old header
  # pill: play button, track name, volume, and the roster to switch.
  attr :id, :string, required: true
  attr :tracks, :list, required: true
  attr :current_track, :atom, required: true

  defp sound_player(assigns) do
    assigns =
      assign(
        assigns,
        :track_name,
        Enum.find_value(assigns.tracks, "Sound", fn {id, name} ->
          id == assigns.current_track && name
        end)
      )

    ~H"""
    <div class="flex-none border-t border-zinc-200 dark:border-zinc-800 p-3 bg-zinc-50/60 dark:bg-zinc-900/40">
      <div
        id={@id}
        phx-hook="SoundPill"
        data-on="text-violet-600 dark:text-violet-400"
        data-off="text-zinc-400 dark:text-zinc-500"
        class="text-zinc-400 dark:text-zinc-500"
      >
        <div class="flex items-center gap-3">
          <button
            type="button"
            data-sound-power
            aria-label="Play or pause the ambient sound"
            title="Play / pause"
            class="focus-ring flex-none inline-flex items-center justify-center w-10 h-10 rounded-full bg-white dark:bg-zinc-800 border border-zinc-200 dark:border-zinc-700 hover:bg-zinc-50 dark:hover:bg-zinc-700 transition-colors"
          >
            <%!-- OFF (paused) → PLAY --%>
            <svg data-sound-icon="off" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5">
              <path d="M6.3 2.84A1 1 0 0 0 5 3.79v12.42a1 1 0 0 0 1.55.83l9.06-6.21a1 1 0 0 0 0-1.66L6.3 2.84Z" />
            </svg>
            <%!-- ON (playing) → PAUSE --%>
            <svg data-sound-icon="on" viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5 hidden">
              <path d="M6 3.5A1.5 1.5 0 0 0 4.5 5v10a1.5 1.5 0 0 0 3 0V5A1.5 1.5 0 0 0 6 3.5Zm8 0A1.5 1.5 0 0 0 12.5 5v10a1.5 1.5 0 0 0 3 0V5A1.5 1.5 0 0 0 14 3.5Z" />
            </svg>
          </button>

          <div class="flex-1 min-w-0">
            <div class="text-sm font-medium text-zinc-700 dark:text-zinc-200 truncate">
              {@track_name}
            </div>
            <input
              type="range"
              min="0"
              max="1"
              step="0.01"
              data-sound-volume
              aria-label="Volume"
              class="mt-1 w-full h-1 cursor-pointer accent-violet-500"
            />
          </div>
        </div>

        <div class="mt-2 flex flex-wrap gap-1">
          <button
            :for={{id, name} <- @tracks}
            type="button"
            phx-click="pick_track"
            phx-value-track={id}
            class={[
              "focus-ring rounded-full px-2.5 py-0.5 text-xs font-medium border transition-colors",
              if(@current_track == id,
                do: "bg-violet-500 border-violet-500 text-white",
                else:
                  "bg-white dark:bg-zinc-800 border-zinc-200 dark:border-zinc-700 text-zinc-500 dark:text-zinc-400 hover:border-violet-300 dark:hover:border-violet-500/40"
              )
            ]}
          >
            {name}
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp state_dot(:needs_you), do: "bg-amber-500"
  defp state_dot(:done), do: "bg-emerald-500"
  defp state_dot(:chugging), do: "bg-violet-500 animate-pulse"
  defp state_dot(_), do: "bg-zinc-400 dark:bg-zinc-500"

  defp state_text(:needs_you), do: "text-amber-600 dark:text-amber-400 font-medium"
  defp state_text(:done), do: "text-emerald-600 dark:text-emerald-400"
  defp state_text(:chugging), do: "text-violet-600 dark:text-violet-400"
  defp state_text(_), do: "text-zinc-500 dark:text-zinc-400"

  defp state_label(:needs_you), do: "needs you"
  defp state_label(:done), do: "done"
  defp state_label(:chugging), do: "working"
  defp state_label(_), do: ""
end
