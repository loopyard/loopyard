defmodule LoopyardWeb.ReviewLive do
  @moduledoc """
  `/decisions` — every decision waiting on you, one DECK (plans/decisions.md).
  A multi-question ask fans out into one slide per question; approvals and
  secrets are one slide each. Newest first. Live: leave it open and new
  decisions join as agents ask.

  `/decisions/:agent_id/:msg_id` is ONE decision with its discussion: the card
  stays on screen while you talk to the operator about it. Messages sent from
  here are tagged to the decision (`Loopyard.ChatAgent.Thread`), so the
  operator's reply lands back on this page — not only in its own chat.

  Built on the FOCUSED VIEW shell (`LoopyardWeb.Components.FocusedView`).
  Sourced from `Loopyard.Attention.line/0` (durable, card-sourced), so nothing
  waiting can be missing. `/projects/:p/workspaces/:w/decisions` scopes to one
  workspace. `/review*` routes are the old name and render the same thing.

  On a phone the deck IS the flipping surface: a vertical scroll with CSS
  proximity snap (no JS gesture emulation — a horizontal swipe fights the
  browser's back gesture on iOS).
  """
  use LoopyardWeb, :live_view

  alias Loopyard.{ChatAgent, Events}
  alias Loopyard.ChatAgent.Thread
  alias LoopyardWeb.Components.FocusedView
  alias LoopyardWeb.Live.WorkspaceLive.Messages
  alias LoopyardWeb.Live.WorkspaceLive.Messages.Cards

  @tick_ms 3_000

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Events.Activity.subscribe_global()
      Process.send_after(self(), :tick, @tick_ms)
    end

    scope = params["workspace_id"]
    history? = socket.assigns.live_action == :history
    socket = socket |> assign(:scope, scope) |> assign(:history?, history?)
    slides = if history?, do: history_slides(), else: slides(scope)

    # A permalink names ONE decision, and that stays a single focused screen —
    # each card is a mini app you can hand someone. Bare /decisions is the DECK.
    focused =
      with aid when is_binary(aid) <- params["agent_id"],
           mid when is_binary(mid) <- params["msg_id"],
           %{} = slide <- Enum.find(slides, &(&1.agent_id == aid and &1.msg_id == mid)) do
        slide.key
      else
        _ -> nil
      end

    operator_id = Loopyard.Operator.agent_id()

    {:ok,
     socket
     |> assign(:focused?, not is_nil(focused))
     |> assign(:slides, slides)
     |> assign(:current, focused || first_key(slides))
     |> assign(:subscribed, MapSet.new())
     |> assign(:last_path, nil)
     |> assign(:operator_id, operator_id)
     |> assign(:thread, [])
     |> assign(:streaming, "")
     |> assign(:user_label, user_label(operator_id))
     |> LoopyardWeb.Live.ConsentUI.attach(secret_scope: scope)
     |> sync_secret_scope()
     |> track_current()
     |> subscribe_agent(operator_id)
     |> load_thread()}
  end

  # Answer updates are CASTS — the card flips via a MessageUpdated broadcast,
  # not synchronously with the click. Subscribe to every slide's agent so the
  # settle renders the instant the update lands (no 3s tick latency).
  defp track_current(socket) do
    socket = Enum.reduce(socket.assigns.slides, socket, &subscribe_agent(&2, &1.agent_id))

    case current_slide(socket) do
      %{} = slide -> assign(socket, :last_path, slide[:path] || socket.assigns.last_path)
      _ -> socket
    end
  end

  defp subscribe_agent(socket, aid) when is_binary(aid) do
    if connected?(socket) and not MapSet.member?(socket.assigns.subscribed, aid) do
      Events.ChatAgentMessage.subscribe(aid)
      assign(socket, :subscribed, MapSet.put(socket.assigns.subscribed, aid))
    else
      socket
    end
  end

  defp subscribe_agent(socket, _), do: socket

  # ── the slide deck ────────────────────────────────────────────────────────
  #
  # One slide per DECISION: each pending question of a multi-question ask is
  # its own slide; an approval or secret is one slide. Slides carry everything
  # the render needs except the live message (fetched fresh per render).

  # Newest first — recency is the right bias for a decision queue: the one
  # asked a minute ago is almost always the one to answer next, and a
  # three-week-old ask is almost never it.
  defp slides(scope) do
    Loopyard.Attention.line()
    |> Enum.filter(&(is_nil(scope) or &1.workspace_id == scope))
    |> Enum.flat_map(&item_slides/1)
    |> Enum.sort_by(&(&1.asked_at || DateTime.from_unix!(0)), {:desc, DateTime})
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # The TIME MACHINE deck: every question/approval/secret ever asked (recent
  # tail per agent), any status, newest first — one slide per CARD (settled
  # receipts render whole).
  defp history_slides do
    ws_names =
      for p <- Loopyard.ProjectRegistry.list_projects(),
          ws <- Loopyard.WorkspaceRegistry.list_workspaces(p.id),
          into: %{} do
        {ws.id, %{project_name: p.name, workspace_name: ws.name, project_id: p.id}}
      end

    for %{id: aid} = st <- ChatAgent.list_agent_summaries(),
        not String.contains?(to_string(st[:name] || ""), "test"),
        msg <- st |> Map.get(:messages, []) |> Enum.take(-200),
        msg[:role] in [:question, :approval, :secret_request] do
      ws = Map.get(ws_names, st[:workspace_id], %{})

      item = %{
        kind: history_kind(msg.role),
        agent_id: aid,
        msg: msg,
        workspace_id: st[:workspace_id],
        project_name: ws[:project_name],
        workspace_name: ws[:workspace_name],
        agent_name: st[:name] || "Agent",
        path: history_path(ws, st),
        asked_at: msg[:timestamp] || DateTime.from_unix!(0)
      }

      slide(item, nil)
    end
    |> Enum.sort_by(& &1.asked_at, {:desc, DateTime})
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp history_kind(:question), do: :question
  defp history_kind(:secret_request), do: :secret
  defp history_kind(:approval), do: :approval

  defp history_path(%{project_id: pid}, st) when is_binary(pid),
    do: "/projects/#{pid}/workspaces/#{st[:workspace_id]}/agents/#{st[:id]}"

  defp history_path(_ws, _st), do: "/operator"

  defp item_slides(%{kind: :question, msg: %{} = msg} = item) do
    for q <- msg[:questions] || [], q.id not in (msg[:done] || []) do
      slide(item, q.id)
    end
  end

  defp item_slides(%{msg: %{}} = item), do: [slide(item, nil)]
  defp item_slides(_), do: []

  defp slide(item, q_id) do
    %{
      key: {item.agent_id, item.msg.id, q_id},
      agent_id: item.agent_id,
      msg_id: item.msg.id,
      q_id: q_id,
      kind: item.kind,
      workspace_id: item.workspace_id,
      project_name: item.project_name,
      workspace_name: item.workspace_name,
      agent_name: item.agent_name,
      path: item.path,
      asked_at: item.asked_at
    }
  end

  defp first_key(slides), do: slides |> List.first() |> then(&(&1 && &1.key))

  # ── queue upkeep ─────────────────────────────────────────────────────────

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, refresh(socket)}
  end

  # Activity events arrive from EVERY agent — a busy fleet fires them in
  # bursts. Coalesce: arm one delayed refresh instead of scanning per event.
  def handle_info(%Events.Activity.Event{}, socket) do
    if socket.assigns[:refresh_armed?] do
      {:noreply, socket}
    else
      Process.send_after(self(), :coalesced_refresh, 250)
      {:noreply, assign(socket, :refresh_armed?, true)}
    end
  end

  def handle_info(:coalesced_refresh, socket),
    do: {:noreply, socket |> assign(:refresh_armed?, false) |> refresh()}

  # The answer's card update just landed — settle NOW, not on the next tick.
  def handle_info(%Events.ChatAgentMessage.MessageUpdated{}, socket),
    do: {:noreply, refresh(socket)}

  # A new message: the operator's reply to the thread (or a new decision card).
  # The thread reloads from the operator's durable messages; a landed reply
  # supersedes whatever was streaming.
  def handle_info(%Events.ChatAgentMessage.Message{agent_id: id} = e, socket) do
    socket =
      if id == socket.assigns.operator_id and e.msg[:role] == :assistant,
        do: assign(socket, :streaming, ""),
        else: socket

    {:noreply, socket |> refresh() |> load_thread()}
  end

  # Live tokens from the operator while it answers the thread. We can't know
  # from a delta which decision it's about, so only show them while THIS
  # thread is the one waiting on a reply.
  def handle_info(%Events.ChatAgentMessage.TextDelta{agent_id: id, text: text}, socket) do
    if id == socket.assigns.operator_id and awaiting_reply?(socket.assigns.thread) do
      {:noreply, assign(socket, :streaming, socket.assigns.streaming <> (text || ""))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # The deck is STICKY: a decision that settles STAYS in the list, rendered as
  # its own receipt, and new ones append. Dropping it the instant it resolved
  # would delete a section from the middle of a page the user is scrolling.
  defp refresh(socket) do
    fresh =
      if socket.assigns.history?,
        do: history_slides(),
        else: slides(socket.assigns.scope)

    socket
    |> assign(:slides, merge_deck(socket.assigns.slides, fresh))
    |> assign(:current, socket.assigns.current || first_key(fresh))
    |> sync_secret_scope()
    |> track_current()
  end

  # Everything already on screen, in the order it was already in, plus whatever
  # is new — new ones go on TOP (newest first), which can only push content
  # DOWN under a reader's thumb, never yank it up.
  defp merge_deck(shown, fresh) do
    seen = MapSet.new(shown, & &1.key)
    Enum.reject(fresh, &MapSet.member?(seen, &1.key)) ++ shown
  end

  # ── the thread (talk about THIS decision) ────────────────────────────────

  # The operator's messages tagged to the focused decision, oldest first.
  defp load_thread(%{assigns: %{focused?: true, operator_id: op}} = socket) when is_binary(op) do
    thread =
      case current_slide(socket) do
        %{agent_id: aid, msg_id: mid} ->
          case ChatAgent.get_state(op) do
            %{messages: messages} when is_list(messages) ->
              Thread.messages_for(messages, {aid, mid})

            _ ->
              []
          end

        _ ->
          []
      end

    assign(socket, :thread, thread)
  rescue
    _ -> assign(socket, :thread, [])
  catch
    _, _ -> assign(socket, :thread, [])
  end

  defp load_thread(socket), do: socket

  defp awaiting_reply?(thread) do
    case List.last(thread) do
      %{role: :user} -> true
      _ -> false
    end
  end

  defp user_label(nil), do: "You"

  defp user_label(operator_id) do
    LoopyardWeb.Live.WorkspaceLive.Components.Chat.Status.workstation_label(
      ChatAgent.get_state(operator_id)
    )
  rescue
    _ -> "You"
  catch
    _, _ -> "You"
  end

  # ── navigation + decisions ───────────────────────────────────────────────

  @impl true
  def handle_event("decide_approval", %{"approval_id" => id, "decision" => decision}, socket) do
    decision = if decision == "approve", do: :approve, else: :deny

    case current_slide(socket) do
      %{agent_id: aid} -> LoopyardWeb.Live.ApprovalActions.decide(aid, id, decision)
      _ -> :ok
    end

    {:noreply, socket}
  end

  # A question ABOUT the focused decision → the operator, tagged to the card
  # (see Thread). Same durability contract as every composer: the box clears
  # only on the agent's ack. The operator is booted here if it isn't up — the
  # one place that cost is worth paying synchronously, since the person just
  # asked it something.
  def handle_event("send_message", %{"message" => text}, socket) do
    text = String.trim(text)

    with true <- text != "",
         %{agent_id: aid, msg_id: mid} <- current_slide(socket),
         op when is_binary(op) <- ensure_operator(socket.assigns.operator_id) do
      socket = socket |> assign(:operator_id, op) |> subscribe_agent(op)

      case ChatAgent.enqueue_message(op, Thread.tag(text, {aid, mid})) do
        :ok ->
          {:reply, %{ok: true}, socket |> assign(:streaming, "") |> load_thread()}

        _ ->
          {:reply,
           %{ok: false, note: "The operator isn't reachable right now — your text is kept."},
           socket}
      end
    else
      nil ->
        {:reply,
         %{ok: false, note: "The operator couldn't start — your text is kept; try again."},
         socket}

      _ ->
        {:reply, %{ok: true}, socket}
    end
  end

  defp ensure_operator(op) when is_binary(op), do: op

  defp ensure_operator(nil) do
    {:ok, %{agent_id: id}} = Loopyard.Operator.ensure_agent()
    id
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp current_slide(socket) do
    Enum.find(socket.assigns.slides, &(&1.key == socket.assigns.current)) ||
      rehydrate(socket.assigns.current)
  end

  # The settled-beat case: the slide left the deck but stays on screen — carry
  # enough to keep rendering it from the current key.
  defp rehydrate(nil), do: nil

  defp rehydrate({aid, mid, q_id}) do
    %{key: {aid, mid, q_id}, agent_id: aid, msg_id: mid, q_id: q_id, kind: nil, path: nil}
    |> Map.merge(%{workspace_id: nil, project_name: nil, workspace_name: nil, agent_name: nil})
  end

  # Secrets submitted here scope to the CURRENT slide's workspace.
  defp sync_secret_scope(socket) do
    assign(
      socket,
      :consent_secret_scope,
      case current_slide(socket) do
        %{workspace_id: ws} when is_binary(ws) -> ws
        _ -> socket.assigns[:scope]
      end
    )
  end

  defp live_msg(nil), do: nil

  defp live_msg(%{agent_id: aid, msg_id: mid}) do
    ChatAgent.get_message(aid, mid)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # ── render ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    # FOCUSED (a permalink) renders exactly one decision. The DECK renders them
    # all, stacked, each resolved to its live message at render time.
    deck =
      if assigns.focused? do
        [Enum.find(assigns.slides, &(&1.key == assigns.current)) || rehydrate(assigns.current)]
      else
        assigns.slides
      end

    cards = deck |> Enum.reject(&is_nil/1) |> Enum.map(&resolve_card/1) |> Enum.reject(&is_nil/1)

    assigns = assign(assigns, :cards, cards)

    ~H"""
    <.review_deck
      cards={@cards}
      focused?={@focused?}
      history?={@history?}
      thread={@thread}
      streaming={@streaming}
      operator_id={@operator_id}
      user_label={@user_label}
    />
    """
  end

  @doc """
  The deck itself, pure: everything below the card-resolution seam.
  `render/1` resolves slides to live messages (ETS) and hands the result
  here; the showcase `reviewer` scene calls this directly with mock cards.
  """
  attr :cards, :list, required: true
  attr :focused?, :boolean, default: false
  attr :history?, :boolean, default: false
  attr :thread, :list, default: []
  attr :streaming, :string, default: ""
  attr :operator_id, :string, default: nil
  attr :user_label, :string, default: "You"

  def review_deck(assigns) do
    assigns =
      assign(
        assigns,
        :pending_count,
        Enum.count(assigns.cards, &(&1.msg.status == :pending))
      )

    ~H"""
    <FocusedView.layout
      label={
        cond do
          @history? -> "Past decisions"
          @focused? -> "Decision"
          true -> "Decisions"
        end
      }
      position={!@focused? && @pending_count > 0 && "#{@pending_count} waiting"}
      mode={:operator}
      snap={!@focused?}
      crumbs={(@focused? && [{"Decisions", "/decisions"}]) || [{"Operator", "/operator"}]}
    >
      <:nav>
        <%!-- Flip between the pending deck and PAST decisions (they're durable
    anyway, so they're traversable). --%>
        <.link
          navigate={(@history? && "/decisions") || "/decisions/history"}
          class="focus-ring tap-target inline-flex items-center justify-center w-9 h-9 rounded-sm text-zinc-500 hover:bg-zinc-100 dark:hover:bg-zinc-800"
          aria-label={(@history? && "Back to pending") || "Past decisions"}
          title={(@history? && "Back to pending") || "Past decisions"}
        >
          <svg viewBox="0 0 20 20" fill="currentColor" class="w-4.5 h-4.5" aria-hidden="true">
            <path
              fill-rule="evenodd"
              d="M10 18a8 8 0 1 0 0-16 8 8 0 0 0 0 16Zm.75-13a.75.75 0 0 0-1.5 0v5c0 .27.144.518.378.651l3.5 2a.75.75 0 1 0 .744-1.302L10.75 9.565V5Z"
              clip-rule="evenodd"
            />
          </svg>
        </.link>
      </:nav>

      <%!-- THE DECK. One continuously scrollable page: every decision stacked,
      each snapping its TOP to the viewport so you land on a question's
      opening line rather than its middle. Snap is PROXIMITY, never
      mandatory — a long question is taller than the screen, and mandatory
      snap fights you the whole way down it. This vertical flip is the
      whole gesture story on a phone: no JS swipe, nothing that competes
      with the browser's own back gesture. --%>
      <div class="space-y-10 md:space-y-16">
        <section :for={card <- @cards} id={"decision-" <> card.dom_id} class="snap-start scroll-mt-4">
          <.decision_source slide={card.slide} msg={card.msg} />

          <%!-- ONE question of a multi-question ask is a bare block, so it needs
      the band + label around it. A whole card (approval, secret, a
      settled question receipt) already IS a band. --%>
          <LoopyardWeb.Components.StreamCard.band
            :if={card.q}
            tone={(card.msg.status == :pending && :needs_you) || :neutral}
            chrome={:desktop}
          >
            <LoopyardWeb.Components.StreamCard.header
              state={:needs_you}
              label_class={
                (card.msg.status == :pending && "text-orange-700 dark:text-orange-400") ||
                  "text-zinc-500 dark:text-zinc-400"
              }
            >
              <:label>
                {(card.msg.status == :pending && "Decision") || "Answered"}
              </:label>
            </LoopyardWeb.Components.StreamCard.header>

            <%!-- No chat_path: the card's "Chat" button navigated AWAY from the
      decision to the source agent's chat — the complaint that started
      the thread below. Discussion happens here; the source chat is a
      link under the card for when you really want the weeds. --%>
            <Cards.question_block msg={card.msg} q={card.q} />
          </LoopyardWeb.Components.StreamCard.band>

          <Cards.question_card
            :if={is_nil(card.q) && card.msg.role == :question}
            msg={card.msg}
          />
          <Cards.approval_card :if={card.msg.role == :approval} msg={card.msg} />
          <Cards.secret_card :if={card.msg.role == :secret_request} msg={card.msg} />

          <div class="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1">
            <.link
              :if={!@focused?}
              navigate={"/decisions/#{card.slide.agent_id}/#{card.slide.msg_id}"}
              class="text-meta font-medium inline-flex items-center min-h-11 md:min-h-0 text-violet-600 dark:text-violet-400 hover:underline"
            >
              Discuss →
            </.link>
            <.link
              :if={card.slide.path}
              navigate={card.slide.path}
              class="text-meta inline-flex items-center min-h-11 md:min-h-0 text-zinc-400 dark:text-zinc-500 hover:text-violet-600 dark:hover:text-violet-400"
            >
              Source chat →
            </.link>
          </div>
        </section>
      </div>

      <%!-- THE THREAD — only on a single decision. The decision stays on screen
      while you talk: once the card scrolls off, the band below PINS under
      the app bar with the question and a way back up to answer it. Pure
      CSS: sticky elements pin at their own natural position, so placed
      AFTER the card it engages exactly when the card has gone. --%>
      <.decision_thread
        :if={@focused? && @cards != []}
        card={hd(@cards)}
        thread={@thread}
        streaming={@streaming}
        operator_id={@operator_id}
        user_label={@user_label}
      />

      <%!-- The END of the deck, not a dead end: when everything is settled this
      is the "you're done" beat. --%>
      <div
        :if={@cards == [] || (@pending_count == 0 && !@history? && !@focused?)}
        class="flex flex-col items-center justify-center gap-4 py-24"
      >
        <p class="text-body text-zinc-400 dark:text-zinc-500">
          {cond do
            @history? -> "No decisions asked yet."
            @cards == [] -> "Nothing waiting on you."
            true -> "All caught up."
          end}
        </p>
        <.link
          :if={!@history?}
          navigate="/decisions/history"
          class="text-body font-medium inline-flex items-center min-h-11 md:min-h-0 text-violet-600 dark:text-violet-400 hover:underline"
        >
          Flip through past decisions →
        </.link>
        <.link
          navigate="/operator"
          class="text-body font-medium inline-flex items-center min-h-11 md:min-h-0 text-violet-600 dark:text-violet-400 hover:underline"
        >
          ← Back to the operator
        </.link>
      </div>
    </FocusedView.layout>
    """
  end

  # WHERE a decision came from, in ONE line: project · workspace (the canonical
  # identity component), who asked, how long ago. It replaced a display-size
  # subject header plus a context line plus a kind eyebrow — six lines of
  # chrome before the question on a phone. The card is the subject here.
  attr :slide, :map, required: true
  attr :msg, :map, required: true

  defp decision_source(assigns) do
    ~H"""
    <div class="mb-3 flex items-center gap-2 min-w-0 text-meta text-zinc-500 dark:text-zinc-400">
      <LoopyardWeb.Components.Common.workspace_identity
        project={@slide.project_name || "Operator"}
        workspace={@slide.workspace_name}
        state={(@msg.status == :pending && :needs_you) || :asleep}
        class="min-w-0"
      />
      <span
        :if={
          is_binary(@slide.agent_name) and
            @slide.agent_name not in [nil, @slide.project_name, "Operator"]
        }
        class="flex-none truncate"
      >
        · {@slide.agent_name}
      </span>
      <span :if={@slide.asked_at} class="flex-none whitespace-nowrap">· {ago(@slide.asked_at)}</span>
    </div>
    """
  end

  attr :card, :map, required: true
  attr :thread, :list, required: true
  attr :streaming, :string, required: true
  attr :operator_id, :string, default: nil
  attr :user_label, :string, required: true

  defp decision_thread(assigns) do
    assigns =
      assign(assigns,
        prompt: card_prompt(assigns.card),
        awaiting?: awaiting_reply?(assigns.thread),
        # The operator's OWN decision, still live: it's parked inside the ask
        # and can't take a question until the card is answered or times out.
        # Say so, instead of a composer that appears to swallow the message.
        blocked?: operator_blocked?(assigns.operator_id, assigns.card)
      )

    ~H"""
    <div id="decision-thread" class="mt-8">
      <div class="sticky top-14 z-10 -mx-4 md:-mx-6 px-4 md:px-6 py-2 flex items-center gap-3 bg-brand-paper dark:bg-brand-ink border-y border-zinc-200 dark:border-zinc-800">
        <p class="min-w-0 flex-1 line-clamp-2 text-body text-zinc-600 dark:text-zinc-300">
          {@prompt}
        </p>
        <a
          href={"#decision-" <> @card.dom_id}
          class="focus-ring flex-none inline-flex items-center min-h-11 md:min-h-9 px-3 rounded-sm text-meta font-semibold text-orange-700 dark:text-orange-400 hover:bg-orange-500/10"
        >
          Answer ↑
        </a>
      </div>

      <div class="pt-4">
        <div class="section-label px-1 pb-1">About this decision</div>

        <p
          :if={@thread == [] and !@blocked?}
          class="px-1 py-2 text-body text-zinc-500 dark:text-zinc-400"
        >
          Ask the operator anything about this — what an option changes, what led
          here, what it would look in the code for. The decision stays put.
        </p>

        <p :if={@blocked?} class="px-1 py-2 text-body text-zinc-500 dark:text-zinc-400">
          This is the operator's own question, and it's waiting on your answer
          before it can do anything else — including discuss it. Answer it above,
          or ask in a moment: anything you send now is queued until it's free.
        </p>

        <div :for={{msg, idx} <- Enum.with_index(@thread)} :key={msg[:id] || idx}>
          <Messages.chat_msg
            msg={msg}
            idx={idx}
            messages={@thread}
            agent_id={@operator_id || "operator"}
            host="localhost"
            detail_level={:chat}
            user_label={@user_label}
          />
        </div>

        <div :if={@streaming != ""} class="px-1 py-2 text-lead whitespace-pre-wrap">
          {@streaming}
        </div>
        <p
          :if={@awaiting? and @streaming == "" and !@blocked?}
          class="px-1 py-2 text-body text-zinc-400 dark:text-zinc-500"
        >
          Thinking…
        </p>
      </div>

      <%!-- The composer, pinned to the bottom like every other chat. Same
      ChatForm hook (ack-gated clear, kept-on-failure) — the ids are its
      contract. --%>
      <div class="sticky bottom-0 -mx-4 md:-mx-6 px-4 md:px-6 pt-2 pb-[max(0.5rem,env(safe-area-inset-bottom))] bg-brand-paper dark:bg-brand-ink border-t border-zinc-200 dark:border-zinc-800">
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
              placeholder="Ask about this decision…"
              aria-label="Ask about this decision"
              autocomplete="off"
              class="focus-ring text-lead flex-1 bg-transparent border-0 rounded-sm px-1 py-2.5 text-zinc-900 dark:text-zinc-100 placeholder:text-zinc-400 resize-none focus:outline-none focus:ring-0"
            ></textarea>
            <button
              type="submit"
              aria-label="Send"
              class="focus-ring flex-none flex items-center justify-center rounded-full w-11 h-11 md:w-10 md:h-10 mb-[5px] md:mb-1 text-violet-600 dark:text-violet-400 hover:bg-violet-50 dark:hover:bg-violet-500/10 transition-colors"
            >
              <LoopyardWeb.Components.Icon.icon name={:arrow_up} class="w-6 h-6" />
            </button>
          </form>
          <p id="send-status" class="hidden mt-1.5 text-lead text-red-500 dark:text-red-400"></p>
        </div>
      </div>
    </div>
    """
  end

  # The question's own words, for the pinned band.
  defp card_prompt(%{q: %{prompt: p}}) when is_binary(p), do: p
  defp card_prompt(%{msg: %{questions: [%{prompt: p} | _]}}) when is_binary(p), do: p
  defp card_prompt(%{msg: msg}), do: Loopyard.CardText.render(msg) |> String.slice(0, 200)

  # Parked means a LIVE ask: the broker still holds a waiter for this agent and
  # its turn is inside the tool call. Status alone is not enough — an operator
  # that is :booting or :thinking to answer THIS thread is busy, not parked.
  defp operator_blocked?(op, %{slide: %{agent_id: op}, msg: %{status: :pending}})
       when is_binary(op) do
    Loopyard.Harness.Questions.pending_for_agent?(op) and
      match?(%{status: s} when s != :idle, ChatAgent.get_state(op))
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp operator_blocked?(_, _), do: false

  # A slide plus its LIVE message and (for a multi-question ask) the one
  # question this card is. Nil when the message has gone — a deleted agent
  # shouldn't leave a hole that crashes the deck.
  defp resolve_card(slide) do
    case live_msg(slide) do
      %{} = msg ->
        %{
          slide: slide,
          msg: msg,
          q: slide.q_id && Enum.find(msg[:questions] || [], &(&1.id == slide.q_id)),
          dom_id: dom_id(slide)
        }

      _ ->
        nil
    end
  end

  defp dom_id(%{agent_id: aid, msg_id: mid, q_id: q_id}),
    do: Enum.join([aid, mid, q_id || "all"], "-")

  defp ago(%DateTime{} = at) do
    secs = DateTime.diff(DateTime.utc_now(), at)

    cond do
      secs < 60 -> "moments ago"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end

  defp ago(_), do: nil
end
