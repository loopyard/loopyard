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

  @aural_channel "activity"
  @rail_tick_ms 3_000
  # Recent-tail size for the chat transcript. Caps the initial LiveView payload
  # so a long-lived operator's history can't blow the WebSocket join frame.
  @message_window 80
  # Hard cap on messages held in the DOM. Scrolling up pages older ones in; once
  # the window overflows this, the live tail is dropped (off-screen anyway) so the
  # DOM never holds the whole history. "Jump to latest" reloads the tail.
  @message_window_max 240
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
      # Mobile only: the chat and the "for you" rail are co-equal on desktop but
      # can't both fit a phone, so we show ONE at a time with a top toggle.
      # Desktop (lg+) ignores this and shows both side-by-side.
      |> assign(:mobile_view, :chat)
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
      # Subscribe to the sub-agents this operator is embedding, so their live
      # windows update as they work — INCLUDING work driven directly, not just
      # what the operator dispatched.
      |> assign(:embedded_ids, MapSet.new())
      |> subscribe_embeds()

    {:ok, socket}
  end

  # The sub-agents referenced by :embed cards in the transcript. Subscribe to any
  # newly-referenced one; the subscription is idempotent per LV (we track which).
  defp subscribe_embeds(socket) do
    ids =
      socket.assigns.messages
      |> Enum.filter(&(&1[:role] == :embed and is_binary(&1[:agent_id])))
      |> MapSet.new(& &1.agent_id)

    if connected?(socket) do
      MapSet.difference(ids, socket.assigns.embedded_ids)
      |> Enum.each(&Events.ChatAgentMessage.subscribe/1)
    end

    assign(socket, :embedded_ids, ids)
  end

  # Force a specific embed card to re-render (re-read the sub-agent's state) by
  # touching its message — the ONLY reliable way past LiveView's component
  # memoization. Never mixes the sub-agent's content into the operator's chat.
  defp touch_embed(socket, agent_id) do
    messages =
      Enum.map(socket.assigns.messages, fn m ->
        if m[:role] == :embed and m[:agent_id] == agent_id,
          do: Map.put(m, :tick, (m[:tick] || 0) + 1),
          else: m
      end)

    assign(socket, :messages, messages)
  end

  # Load the agent summary + transcript into the workspace-chat assign shape:
  # `agents` is a one-element list so `AgentEvents.refresh_selected_from_agents`
  # (ETS-counter merge) finds it. Used at mount + after an approval decision (the
  # one message-*update* path with no incremental event to ride).
  defp load_agent(socket) do
    case ChatAgent.get_state(socket.assigns.agent_id) do
      %{} = st ->
        all = st.messages || []
        # WINDOW the transcript. The operator was built for "short chats" with
        # windowing off, but a long-lived operator accumulates hundreds of turns —
        # rendering all of them made the initial LiveView payload ~1 MB, which
        # blows the WebSocket frame on join (Bandit closes the socket at the
        # protocol level — no Elixir error, just a perpetual "connection lost —
        # reconnecting"). Render only the recent tail; the full history still
        # lives in the durable log.
        windowed = Enum.take(all, -@message_window)

        socket
        |> assign(:selected_agent, st)
        |> assign(:agents, [st])
        |> assign(:messages, windowed)
        |> assign(:has_more_messages, length(all) > length(windowed))

      _ ->
        stub = %{id: socket.assigns.agent_id, status: :idle}

        socket
        |> assign(:selected_agent, stub)
        |> assign(:agents, [stub])
        |> assign(:messages, [])
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
  # Mobile: flip between the chat and the "for you" rail.
  # PerfProbe (chat_panel's client-health beacon) reports here too — without
  # this clause every jank sample CRASHED the LiveView it was reporting on
  # (FunctionClauseError → remount), which read as "the app feels unreliable".
  def handle_event("perf_sample", sample, socket) when is_map(sample) do
    max_gap = sample["max_gap_ms"]

    if is_number(max_gap) and max_gap > 100 do
      Loopyard.EventLog.warning(
        "perf",
        "client jank: max_gap=#{max_gap}ms over50=#{sample["gaps_over_50"]} " <>
          "dom=#{sample["dom"]} heap=#{sample["heap_mb"]}MB agent=#{socket.assigns.agent_id}"
      )
    end

    {:noreply, socket}
  end

  def handle_event("mobile_view", %{"v" => v}, socket) when v in ~w(chat rail) do
    {:noreply, assign(socket, :mobile_view, String.to_existing_atom(v))}
  end

  # Scroll-up paging: the ScrollBottom hook fires this near the top. Prepend the
  # next older batch from the durable log, capped at @message_window_max so the
  # DOM never holds the whole history — on overflow we drop from the TAIL (it's
  # off-screen while you read up here), which stops the window following the live
  # stream until "jump to latest" (load_latest) snaps back.
  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more_messages && socket.assigns.selected_id do
      oldest = List.first(socket.assigns.messages)

      {older, _total} =
        ChatAgent.get_messages(socket.assigns.selected_id,
          limit: @message_window,
          before_id: oldest && oldest[:id],
          snap_to_prompt: true
        )

      if older != [] do
        combined = older ++ socket.assigns.messages

        {windowed, tail?} =
          if length(combined) > @message_window_max do
            {Enum.take(combined, @message_window_max), false}
          else
            {combined, socket.assigns.window_tail?}
          end

        {:noreply,
         socket
         |> assign(:messages, windowed)
         |> assign(:has_more_messages, true)
         |> assign(:window_tail?, tail?)}
      else
        {:noreply, assign(socket, :has_more_messages, false)}
      end
    else
      {:noreply, socket}
    end
  end

  # Jump back to the live tail after scrolling up past the DOM cap: reload the
  # last window from the agent and snap to the bottom (catches up any messages we
  # didn't append while window_tail? was false).
  def handle_event("load_latest", _params, socket) do
    case socket.assigns.selected_id do
      nil ->
        {:noreply, socket}

      id ->
        all = (ChatAgent.get_state(id) || %{})[:messages] || []
        page = Enum.take(all, -@message_window)

        {:noreply,
         socket
         |> assign(:messages, page)
         |> assign(:has_more_messages, length(page) < length(all))
         |> assign(:window_tail?, true)
         |> push_event("jump_bottom", %{})}
    end
  end

  def handle_event(_evt, _params, socket), do: {:noreply, socket}

  # Opacity by how long since the workspace was last active. Recent work stays
  # bright; older work dims and recedes. Floored at 50% so a faded row is still
  # readable WITHOUT hover (mobile has none) — hover/tap restores full weight.
  # This makes recency visual, not just the sort order.
  defp fade_class(%DateTime{} = at, now) do
    case DateTime.diff(now, at, :minute) do
      m when m < 10 -> "opacity-100"
      m when m < 60 -> "opacity-75"
      m when m < 360 -> "opacity-60"
      _ -> "opacity-50"
    end
  end

  defp fade_class(_, _), do: "opacity-50"

  # Recency GROUPS instead of a fade: readable at any age, and recency reads from
  # the section label ("Recently" / "Past hour" / "Today" / "Earlier"), not from
  # dimming rows to near-invisible. Returns a list of {label, items}, non-empty
  # groups only, in newest→oldest order.
  @recency_order [
    {:recently, "Recently"},
    {:hour, "Past hour"},
    {:day, "Today"},
    {:older, "Earlier"}
  ]

  defp bucket_done(done, now) do
    by = Enum.group_by(done, &recency_bucket(&1[:last_activity_at], now))

    for {key, label} <- @recency_order,
        items = Map.get(by, key, []),
        items != [],
        do: {label, items}
  end

  defp recency_bucket(%DateTime{} = at, now) do
    case DateTime.diff(now, at, :minute) do
      m when m < 15 -> :recently
      m when m < 60 -> :hour
      m when m < 1440 -> :day
      _ -> :older
    end
  end

  defp recency_bucket(_, _), do: :older

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

    now = DateTime.utc_now()

    jobs =
      tree
      |> Loopyard.Operator.Queue.items()
      |> Enum.map(fn j ->
        j
        |> Map.put(:watching?, MapSet.member?(watched, j.id))
        # Fade by staleness — makes recency visual, used on the "wrapped" tier.
        |> Map.put(:fade, fade_class(j[:last_activity_at], now))
      end)

    # A chief of staff shows what NEEDS you, not a roster. "In motion" = anything
    # worth your eyes: actively running, awaiting you, OR done-but-unseen (it has
    # new changes since you last looked). Everything else drops to a quiet
    # "recently wrapped" tier, deduped by project so two done workspaces of one
    # project don't read as "gbrain gbrain".
    {active, done} =
      Enum.split_with(jobs, &(&1.state in [:chugging, :needs_you] or &1.delta > 0))

    done = Enum.uniq_by(done, & &1.project_name)

    socket
    |> assign(:tree, tree)
    |> assign(:attention_groups, groups)
    |> assign(
      :attention_by_ws,
      Enum.group_by(Enum.reject(line, &(&1.agent_id == op)), & &1.workspace_id)
    )
    # The OPERATOR's own pending asks — no workspace row to nest under, so the
    # rail gives them their own block up top (they also render inline in the
    # chat, but "For you" must show EVERYTHING waiting).
    |> assign(:operator_attention, Enum.filter(line, &(&1.agent_id == op)))
    |> assign(:active_jobs, active)
    # Grouped by how long ago they wrapped — Recently / Past hour / Today /
    # Earlier — instead of one list dimmed by age. Calmer, and readable (no fade).
    |> assign(:done_buckets, bucket_done(done, now))
    # Header count = ALL blocking items (same line the /review queue works);
    # the rail groups exclude the operator's own (those show in the chat).
    |> assign(:needs_you_count, length(line))
  end

  # --- Message + streaming events: delegate to the SAME handlers the workspace
  # chat uses, so the operator gets incremental append + live streaming. ---

  @impl true
  def handle_info(%Events.ChatAgentMessage.Message{agent_id: id} = e, socket) do
    cond do
      id == socket.assigns.agent_id ->
        # The operator's own message → normal chat handling. A new :embed card may
        # reference a new sub-agent, so re-check subscriptions.
        {:noreply, socket} = AgentEvents.handle_message(e, socket)
        {:noreply, subscribe_embeds(socket)}

      MapSet.member?(socket.assigns.embedded_ids, id) ->
        # A sub-agent we embed produced a message → refresh its live window ONLY;
        # never fold a sub-agent's content into the operator's own transcript.
        {:noreply, touch_embed(socket, id)}

      true ->
        {:noreply, socket}
    end
  end

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
    do:
      {:noreply, push_event(socket, "aural_command", %{action: to_string(action), value: value})}

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
        %Events.ChatAgentMessage.StreamOutput{
          agent_id: id,
          data: data,
          title: title,
          msg_id: msg_id
        },
        socket
      )
      when id == socket.assigns.selected_id do
    stream_buffer =
      StreamBuffer.append(socket.assigns.stream_buffer, data, title: title, msg_id: msg_id)

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
    socket = refresh_rail(socket)

    # If it's an agent we embed, refresh its live window too (working → ready).
    socket =
      if MapSet.member?(socket.assigns.embedded_ids, e.id),
        do: touch_embed(socket, e.id),
        else: socket

    {:noreply, socket}
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
    # Badge on the mobile "For you" tab: how many blocking items are waiting.
    assigns =
      assign(
        assigns,
        :needs_count,
        Enum.sum(Enum.map(assigns.attention_groups, &length(&1.items)))
      )

    ~H"""
    <div
      id="operator-page"
      phx-hook="ScrollBottom"
      class="h-screen flex flex-col bg-brand-paper dark:bg-brand-ink text-zinc-900 dark:text-zinc-100 safe-area-x"
    >
      <Nav.bar height="h-14" gap="gap-3">
        <.breadcrumbs crumbs={[{"Loopyard", "/"}, {"Operator", nil}]} />
        <:actions>
          <LoopyardWeb.Components.Common.mode_nav active={:operator} />
          <%!-- No "Needs you" pill — the rail shows blocking items right there.
    Sound is a player docked at the bottom of the rail. --%>
        </:actions>
      </Nav.bar>

      <%!-- Mobile only: chat ⇄ rail toggle. Both panes are co-equal but can't
    share a phone screen, so show one at a time. Hidden on lg+ (both show). --%>
      <%!-- Finger-sized tabs: this bar is mobile-only, so padding is sized for
    touch (py-4, text-base ≈ 48px target), not for a pointer. --%>
      <div class="lg:hidden flex-none flex border-b border-zinc-200 dark:border-zinc-800 text-base">
        <button
          type="button"
          phx-click="mobile_view"
          phx-value-v="chat"
          class={[
            "flex-1 py-4 font-medium text-center border-b-2 -mb-px transition-colors",
            (@mobile_view == :chat && "border-violet-500 text-violet-600 dark:text-violet-400") ||
              "border-transparent text-zinc-500 dark:text-zinc-400"
          ]}
        >
          Chat
        </button>
        <button
          type="button"
          phx-click="mobile_view"
          phx-value-v="rail"
          class={[
            "flex-1 py-4 font-medium text-center border-b-2 -mb-px transition-colors inline-flex items-center justify-center gap-1.5",
            (@mobile_view == :rail && "border-violet-500 text-violet-600 dark:text-violet-400") ||
              "border-transparent text-zinc-500 dark:text-zinc-400"
          ]}
        >
          For you
          <span
            :if={@needs_count > 0}
            class="inline-flex items-center justify-center min-w-[1.25rem] h-5 px-1 rounded-full bg-violet-600 text-white text-xs font-semibold tabular-nums"
          >
            {@needs_count}
          </span>
        </button>
      </div>

      <div class="flex-1 min-h-0 flex">
        <%!-- Chat is PRIMARY — mostly you just talk to the operator. --%>
        <div class={[
          "flex-1 min-w-0 flex-col min-h-0",
          (@mobile_view == :chat && "flex") || "hidden",
          "lg:flex"
        ]}>
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
        <aside class={[
          "flex-none flex-col border-l border-zinc-200 dark:border-zinc-800 bg-zinc-50/60 dark:bg-zinc-900/40",
          "w-full lg:w-72 xl:w-80",
          (@mobile_view == :rail && "flex") || "hidden",
          "lg:flex"
        ]}>
          <div class="flex-1 min-h-0 overflow-y-auto">
            <.for_you_rail
              operator_attention={@operator_attention}
              attention_by_ws={@attention_by_ws}
              groups={@attention_groups}
              active={@active_jobs}
              done_buckets={@done_buckets}
            />
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
  attr :operator_attention, :list, default: []
  attr :attention_by_ws, :map, default: %{}
  attr :groups, :list, required: true
  attr :active, :list, required: true
  attr :done_buckets, :list, required: true

  # One-line gist for a rail row: the first question's prompt (or the secret's
  # name) — enough to recognize, not the whole card.
  defp attention_summary(%{kind: :question, msg: %{questions: [q | _]}}), do: q.prompt
  defp attention_summary(%{kind: :secret, msg: %{name: name}}), do: "Needs a secret: #{name}"
  defp attention_summary(item), do: item[:label] || "Needs your input"

  defp for_you_rail(assigns) do
    ~H"""
    <div class="flex flex-col">
      <%!-- The OPERATOR's own questions — no workspace row to nest under, so
           they lead the rail. Same flame mini-language; tap → the Reviewer. --%>
      <section :if={@operator_attention != []} class="p-3 pb-0">
        <div class="text-[11px] font-medium uppercase tracking-wide text-orange-700/80 dark:text-orange-400/80 px-1 pb-1">
          Operator · needs you
        </div>
        <div class="space-y-0.5">
          <.link
            :for={item <- @operator_attention}
            navigate={(item.msg && "/review/#{item.agent_id}/#{item.msg.id}") || "/review"}
            class="flex items-center gap-2.5 rounded-sm px-2 py-2 lg:py-1.5 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
          >
            <svg
              viewBox="0 0 16 16"
              fill="currentColor"
              class="w-3.5 h-3.5 flex-none text-orange-600 dark:text-orange-400"
              aria-hidden="true"
            ><path
              fill-rule="evenodd"
              d="M8 15A7 7 0 1 0 8 1a7 7 0 0 0 0 14Zm.93-9.412c-.44-.305-1.054-.305-1.494 0-.146.101-.27.245-.354.435a.75.75 0 0 1-1.372-.606c.18-.405.45-.74.819-.995 1.041-.722 2.486-.722 3.527 0 .54.375.94.94.94 1.626 0 .609-.314 1.07-.658 1.39-.124.115-.26.222-.387.32l-.10.078c-.179.139-.31.255-.404.385-.087.12-.12.222-.12.334a.75.75 0 0 1-1.5 0c0-.49.218-.884.47-1.226.21-.286.482-.502.679-.654l.078-.06c.139-.108.224-.18.286-.237.087-.08.108-.13.108-.27a.484.484 0 0 0-.298-.473ZM8 12a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z"
              clip-rule="evenodd"
            /></svg>
            <span class="flex-1 min-w-0 truncate chat-meta text-zinc-700 dark:text-zinc-200">
              {attention_summary(item)}
            </span>
          </.link>
        </div>
      </section>

      <%!-- IN MOTION — what's actually RUNNING right now, prominent. Delta sits
    INLINE next to the name (not floated across the rail), so it reads as
    one line. The row taps through to the workspace agent (the weeds). --%>
      <section class="p-3 border-t border-zinc-200 dark:border-zinc-800">
        <div class="text-xs font-semibold uppercase tracking-wide text-zinc-400 dark:text-zinc-500 px-1 pb-1.5">
          In motion
        </div>
        <p :if={@active == []} class="px-1 py-1 text-sm text-zinc-500 dark:text-zinc-400">
          Nothing running right now.
        </p>
        <div :for={i <- @active}>
          <div
            phx-click="open_job"
            phx-value-ws={i.id}
            phx-value-project={i.project_id}
            phx-value-agent={i.agent_id}
            title={"#{i.project_name} · #{i.workspace_name} — #{state_label(i.state)}"}
            class="group flex items-center gap-2.5 rounded-sm px-2.5 py-3 lg:py-1.5 cursor-pointer hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
          >
            <.workspace_identity
              project={i.project_name}
              workspace={i.workspace_name}
              state={(i.state == :chugging && :working) || i.state}
              class="flex-1"
            />
            <span
              :if={i.delta > 0}
              title={"#{i.delta} new since you last looked"}
              class="flex-none text-xs font-semibold text-violet-600 dark:text-violet-400 tabular-nums"
            >
              {i.delta} new
            </span>
            <span class="ml-auto flex-none text-xs font-medium text-violet-600 dark:text-violet-400 opacity-0 group-hover:opacity-100 transition-opacity">
              dive in →
            </span>
          </div>
          <%!-- The workspace's OPEN QUESTIONS, nested right under its row — the
             flame mini-language (the question's own words). Tap → the Reviewer
             at that item. Capped at 3; the rest are one tap away. --%>
          <div :if={Map.get(@attention_by_ws, i.id, []) != []} class="pl-4 pb-1 space-y-0.5">
            <.link
              :for={item <- Enum.take(Map.get(@attention_by_ws, i.id, []), 3)}
              navigate={
                (item.msg && "/review/#{item.agent_id}/#{item.msg.id}") ||
                  "/projects/#{i.project_id}/workspaces/#{i.id}/review"
              }
              class="flex items-center gap-2.5 rounded-sm px-2 py-2 lg:py-1.5 hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
            >
              <svg
                viewBox="0 0 16 16"
                fill="currentColor"
                class="w-3.5 h-3.5 flex-none text-orange-600 dark:text-orange-400"
                aria-hidden="true"
              ><path
                fill-rule="evenodd"
                d="M8 15A7 7 0 1 0 8 1a7 7 0 0 0 0 14Zm.93-9.412c-.44-.305-1.054-.305-1.494 0-.146.101-.27.245-.354.435a.75.75 0 0 1-1.372-.606c.18-.405.45-.74.819-.995 1.041-.722 2.486-.722 3.527 0 .54.375.94.94.94 1.626 0 .609-.314 1.07-.658 1.39-.124.115-.26.222-.387.32l-.10.078c-.179.139-.31.255-.404.385-.087.12-.12.222-.12.334a.75.75 0 0 1-1.5 0c0-.49.218-.884.47-1.226.21-.286.482-.502.679-.654l.078-.06c.139-.108.224-.18.286-.237.087-.08.108-.13.108-.27a.484.484 0 0 0-.298-.473ZM8 12a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z"
                clip-rule="evenodd"
              /></svg>
              <span class="flex-1 min-w-0 truncate chat-meta text-zinc-700 dark:text-zinc-200">
                {attention_summary(item)}
              </span>
            </.link>
            <.link
              :if={length(Map.get(@attention_by_ws, i.id, [])) > 3}
              navigate={"/projects/#{i.project_id}/workspaces/#{i.id}/review"}
              class="block pl-2.5 chat-meta text-orange-700 dark:text-orange-400 hover:underline"
            >
              +{length(Map.get(@attention_by_ws, i.id, [])) - 3} more →
            </.link>
          </div>
        </div>

        <%!-- WRAPPED work, grouped by how long ago (Recently / Past hour / Today
    / Earlier). Full size + full opacity at every age — recency reads
    from the section label, not from dimming rows away. --%>
        <div :for={{label, items} <- @done_buckets} class="mt-3">
          <div class="text-[11px] font-medium uppercase tracking-wide text-zinc-400/80 dark:text-zinc-600 px-1 pb-1">
            {label}
          </div>
          <div
            :for={i <- items}
            phx-click="open_job"
            phx-value-ws={i.id}
            phx-value-project={i.project_id}
            phx-value-agent={i.agent_id}
            title={"#{i.project_name} · #{i.workspace_name} — done"}
            class="group flex items-center gap-2 rounded-sm px-2.5 py-3 lg:py-1.5 cursor-pointer hover:bg-zinc-100 dark:hover:bg-zinc-800/60 transition-colors"
          >
            <.workspace_identity
              project={i.project_name}
              workspace={i.workspace_name}
              state={:done}
              size={:md}
              class="flex-1"
            />
            <span class="ml-auto flex-none text-[11px] font-medium text-violet-500 opacity-0 group-hover:opacity-100 transition-opacity">
              →
            </span>
          </div>
        </div>
        <%!-- Workstations — the operator's own identities/creds live in this
             mode (plans/ia-two-modes.md). A quiet footer destination. --%>
        <.link
          navigate="/workstations"
          class="mt-4 flex items-center gap-2 -mx-1 px-1 py-2 chat-meta text-zinc-500 dark:text-zinc-400 hover:text-violet-600 dark:hover:text-violet-400 transition-colors"
        >
          Workstations →
        </.link>
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
            <%!-- Track name is the "change it" affordance: tap → the full /sound
    UI (picker). The chevron signals it's tappable. --%>
            <.link
              navigate={~p"/sound"}
              title="Change the track"
              class="focus-ring group -mx-1 inline-flex max-w-full items-center gap-1 rounded-sm px-1 py-0.5 hover:bg-zinc-200/60 dark:hover:bg-zinc-700/60 transition-colors"
            >
              <span class="text-sm font-medium text-zinc-700 dark:text-zinc-200 truncate">
                {@track_name}
              </span>
              <svg
                viewBox="0 0 20 20"
                fill="currentColor"
                class="w-3.5 h-3.5 flex-none text-zinc-400 group-hover:text-zinc-600 dark:group-hover:text-zinc-300"
              >
                <path
                  fill-rule="evenodd"
                  d="M7.21 14.77a.75.75 0 0 1 .02-1.06L11.168 10 7.23 6.29a.75.75 0 1 1 1.04-1.08l4.5 4.25a.75.75 0 0 1 0 1.08l-4.5 4.25a.75.75 0 0 1-1.06-.02Z"
                  clip-rule="evenodd"
                />
              </svg>
            </.link>
            <input
              type="range"
              min="0"
              max="1"
              step="0.01"
              data-sound-volume
              aria-label="Volume"
              class="volume-slider mt-1"
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp state_label(:needs_you), do: "needs you"
  defp state_label(:done), do: "done"
  defp state_label(:chugging), do: "working"
  defp state_label(_), do: ""
end
