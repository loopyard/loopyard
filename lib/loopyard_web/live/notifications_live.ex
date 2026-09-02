defmodule LoopyardWeb.NotificationsLive do
  @moduledoc """
  `/notifications` — the TEAM's inbox: every decision waiting on a human, one
  DECK you swipe through (plans/decisions.md). Its own root, a peer of the
  operator (not a tab under it): agents raise decisions with their own tools
  (`ask_user`, approvals, `request_secret`) — each shows in that agent's chat
  AND here — and anyone can answer. A multi-question ask fans out into one
  slide per question; approvals and secrets are one slide each. Newest
  first. Live: leave it open and new decisions join as agents ask.

  **Two axes, both native scrolling, no JS gestures.** The deck is a
  horizontal CSS scroll-snap carousel: swipe left/right to move between
  decisions. Each slide is its own vertical scroller with its OWN top bar —
  who's asking is the title, so the title travels with the swipe — the
  decision under it, and the discussion below. Scroll into the discussion
  and the card COLLAPSES into a sticky orange band (the question, tap to pop
  back up) — the `StickyShadow` hook flips `data-stuck`; CSS does the rest.

  A message sent from a slide is tagged to that decision
  (`Loopyard.ChatAgent.Thread`), so the operator's reply lands back on the
  slide — not only in its own chat. `/decisions/:agent_id/:msg_id` is the
  same deck opened AT that decision (the slide takes focus on mount, which
  scrolls the carousel to it — no custom JS).

  Sourced from `Loopyard.Notifications` (durable, card-sourced), so nothing
  waiting can be missing, and live on its events. A finished turn is a slide
  too: what the agent said last, and Keep going / Open / Dismiss. `/projects/:p/workspaces/:w/decisions` scopes to one
  workspace. `/review*` routes are the old name and render the same thing.
  """
  use LoopyardWeb, :live_view

  alias Loopyard.{ChatAgent, Events}
  alias Loopyard.ChatAgent.Thread
  alias LoopyardWeb.NotificationsLive.{Deck, Slide}
  alias LoopyardWeb.Components.AppShell

  @tick_ms 3_000

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Events.Notifications.subscribe()
      Events.Activity.subscribe_global()
      Process.send_after(self(), :tick, @tick_ms)
    end

    scope = params["workspace_id"]
    history? = socket.assigns.live_action == :history
    socket = socket |> assign(:scope, scope) |> assign(:history?, history?)
    slides = if history?, do: Deck.history(), else: Deck.pending(scope)

    # A permalink names ONE decision: the deck opens there.
    target =
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
     |> assign(:target, target)
     |> assign(:pending_keys, pending_keys(slides))
     |> assign(:advance_from, nil)
     |> assign(:slides, slides)
     |> assign(:subscribed, MapSet.new())
     |> assign(:operator_id, operator_id)
     |> assign(:threads, %{})
     |> assign(:queued, %{})
     |> assign(:operator_status, nil)
     |> assign(:streaming, "")
     |> assign(:awaiting, nil)
     |> assign(:user_label, user_label(operator_id))
     |> assign(:vapid_key, Loopyard.WebPush.public_key())
     |> LoopyardWeb.Live.ConsentUI.attach(secret_scope: scope)
     |> sync_secret_scope()
     |> subscribe_slides()
     |> subscribe_agent(operator_id)
     |> load_threads()}
  end

  # Answer updates are CASTS — the card flips via a MessageUpdated broadcast,
  # not synchronously with the click. Subscribe to every slide's agent so the
  # settle renders the instant the update lands (no 3s tick latency).
  defp subscribe_slides(socket),
    do: Enum.reduce(socket.assigns.slides, socket, &subscribe_agent(&2, &1.agent_id))

  defp subscribe_agent(socket, aid) when is_binary(aid) do
    if connected?(socket) and not MapSet.member?(socket.assigns.subscribed, aid) do
      Events.ChatAgentMessage.subscribe(aid)
      assign(socket, :subscribed, MapSet.put(socket.assigns.subscribed, aid))
    else
      socket
    end
  end

  defp subscribe_agent(socket, _), do: socket

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

  # The inbox changed (raised / settled / dismissed / retracted, anywhere):
  # the deck is a view of it.
  def handle_info(%Events.Notifications.Added{}, socket), do: {:noreply, refresh(socket)}
  def handle_info(%Events.Notifications.Changed{}, socket), do: {:noreply, refresh(socket)}

  # A new message: the operator's reply to a thread (or a new decision card).
  # Threads reload from the operator's durable messages; a landed reply
  # supersedes whatever was streaming.
  def handle_info(%Events.ChatAgentMessage.Message{agent_id: id} = e, socket) do
    socket =
      if id == socket.assigns.operator_id and e.msg[:role] == :assistant,
        do: assign(socket, streaming: "", awaiting: nil),
        else: socket

    {:noreply, socket |> refresh() |> load_threads()}
  end

  # Live tokens from the operator while it answers a thread. A delta doesn't
  # say which decision it's about, so they show only under the thread that is
  # waiting on a reply — the one this viewer last sent to.
  def handle_info(%Events.ChatAgentMessage.TextDelta{agent_id: id, text: text}, socket) do
    if id == socket.assigns.operator_id and socket.assigns.awaiting do
      {:noreply, assign(socket, :streaming, socket.assigns.streaming <> (text || ""))}
    else
      {:noreply, socket}
    end
  end

  # SETTLED BEAT → ADVANCE. When a decision on the deck settles (answered or
  # dismissed, here or anywhere), hold for a beat so the receipt registers,
  # then move the deck to the next slide — the slide takes focus, which
  # scrolls the carousel natively. The settled slide stays in the deck
  # behind you (swipe back to see it). One-shot: the marker clears itself.
  def handle_info({:advance_after, key}, socket) do
    Process.send_after(self(), :advance_done, 2_000)
    {:noreply, assign(socket, :advance_from, key)}
  end

  def handle_info(:advance_done, socket), do: {:noreply, assign(socket, :advance_from, nil)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # The deck is STICKY: a decision that settles STAYS, rendered as its own
  # receipt, and new ones join. Dropping a slide the instant it resolved would
  # shift every slide after it under the reader's thumb.
  defp refresh(socket) do
    fresh =
      if socket.assigns.history?,
        do: Deck.history(),
        else: Deck.pending(socket.assigns.scope)

    slides = Deck.merge(socket.assigns.slides, fresh)
    now_pending = pending_keys(slides)

    # Anything pending a moment ago that isn't now just settled.
    socket.assigns.pending_keys
    |> MapSet.difference(now_pending)
    |> Enum.each(&Process.send_after(self(), {:advance_after, &1}, 700))

    socket
    |> assign(:slides, slides)
    |> assign(:pending_keys, now_pending)
    |> sync_secret_scope()
    |> subscribe_slides()
    |> load_threads()
  end

  # ── the threads (talk about THIS decision) ───────────────────────────────

  # The operator's messages tagged to each decision on the deck, oldest first,
  # keyed by decision ref. One ETS read for all of them.
  # Also what's PARKED: a message sent while the operator was busy sits in its
  # pending queue, not its messages — invisible here until it drained, which
  # read as "I hit send and it's gone". Parked texts still carry their marker,
  # so they group by decision the same way. And the operator's status, so the
  # thread can say what's actually happening while you wait.
  defp load_threads(%{assigns: %{operator_id: op}} = socket) when is_binary(op) do
    case ChatAgent.get_state(op) do
      %{messages: messages} = st when is_list(messages) ->
        threads =
          messages
          |> Enum.filter(&match?({_, _}, &1[:re]))
          |> Enum.group_by(& &1[:re])

        # The summary names the parked queue `pending_messages`; a live state
        # says `pending_sends`. Read both — reading only the latter is why the
        # queued band never showed.
        queued =
          (st[:pending_messages] || st[:pending_sends] || [])
          |> Enum.map(&Thread.split/1)
          |> Enum.filter(&match?({_, {_, _}}, &1))
          |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))

        assign(socket, threads: threads, queued: queued, operator_status: st[:status])

      _ ->
        assign(socket, threads: %{}, queued: %{}, operator_status: nil)
    end
  rescue
    _ -> assign(socket, threads: %{}, queued: %{}, operator_status: nil)
  catch
    _, _ -> assign(socket, threads: %{}, queued: %{}, operator_status: nil)
  end

  defp load_threads(socket), do: socket

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

    # The approval id is unique across agents; find the slide it belongs to.
    case Enum.find(socket.assigns.slides, &(&1.msg_id == id)) do
      %{agent_id: aid} -> LoopyardWeb.Live.ApprovalActions.decide(aid, id, decision)
      _ -> :ok
    end

    {:noreply, socket}
  end

  # A question ABOUT a decision → the operator, tagged to the card (see
  # Thread). `re` comes from the slide's own composer. Same durability
  # contract as every composer: the box clears only on the agent's ack. The
  # operator is booted here if it isn't up — the one place that cost is worth
  # paying synchronously, since the person just asked it something.
  # Push for THIS device (the PushBell hook owns permission + subscription
  # client-side; the server stores/deletes and the kinds it wants). The bell
  # lives here, on the inbox, so a phone can subscribe — it used to exist only
  # in the operator's desktop rail.
  def handle_event("push_subscribe", %{"subscription" => sub} = params, socket) do
    kinds = if params["finished"], do: ["finished"], else: []

    case Loopyard.WebPush.subscribe(sub, kinds) do
      :ok ->
        Loopyard.EventLog.info("notifications", "push notifications enabled for a device")

        Loopyard.WebPush.notify_one(
          sub,
          "Notifications on",
          "Decisions land here — tapping one opens it.",
          "/notifications"
        )

        {:reply, %{ok: true}, socket}

      _ ->
        {:reply, %{ok: false}, socket}
    end
  end

  def handle_event("push_unsubscribe", %{"endpoint" => endpoint}, socket) do
    Loopyard.WebPush.unsubscribe(endpoint)
    {:reply, %{ok: true}, socket}
  end

  def handle_event("push_kinds", %{"endpoint" => endpoint} = params, socket) do
    Loopyard.WebPush.set_kinds(endpoint, if(params["finished"], do: ["finished"], else: []))
    {:reply, %{ok: true}, socket}
  end

  # Finished-turn slides: the primary move, and the discard. Keep going hands
  # the agent its next prompt (the composer's text, or the plain word).
  def handle_event("keep_going", %{"id" => id} = params, socket) do
    text = String.trim(params["message"] || "")
    Loopyard.Notifications.keep_going(id, (text != "" && text) || "Keep going.")
    {:noreply, socket}
  end

  def handle_event("dismiss_item", %{"id" => id}, socket) do
    Loopyard.Notifications.dismiss(id, socket.assigns.user_label)
    {:noreply, socket}
  end

  def handle_event("send_message", %{"message" => text} = params, socket) do
    text = String.trim(text)

    with true <- text != "",
         {:ok, ref} <- parse_ref(params["re"]),
         false <- finished_ref?(ref),
         op when is_binary(op) <- ensure_operator(socket.assigns.operator_id) do
      socket = socket |> assign(:operator_id, op) |> subscribe_agent(op)

      case ChatAgent.enqueue_message(op, Thread.tag(text, ref)) do
        :ok ->
          {:reply, %{ok: true}, socket |> assign(streaming: "", awaiting: ref) |> load_threads()}

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

      # A finished-turn slide's composer is "what's next" for THAT agent.
      true ->
        {:ok, {aid, _}} = parse_ref(params["re"])

        case Loopyard.Notifications.keep_going("fin:" <> aid, text) do
          :ok ->
            {:reply, %{ok: true}, socket}

          _ ->
            {:reply, %{ok: false, note: "That agent didn't take it — your text is kept."}, socket}
        end

      _ ->
        {:reply, %{ok: true}, socket}
    end
  end

  defp finished_ref?({_aid, mid}), do: mid == Deck.finished_msg_id()

  defp parse_ref(re) when is_binary(re) do
    case String.split(re, ":", parts: 2) do
      [aid, mid] when aid != "" and mid != "" -> {:ok, {aid, mid}}
      _ -> :error
    end
  end

  defp parse_ref(_), do: :error

  defp ensure_operator(op) when is_binary(op), do: op

  defp ensure_operator(nil) do
    {:ok, %{agent_id: id}} = Loopyard.Operator.ensure_agent()
    id
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Secrets submitted here scope to the deck's workspace (or none).
  defp sync_secret_scope(socket),
    do: assign(socket, :consent_secret_scope, socket.assigns[:scope])

  # The slides still waiting on a human: a question slide until ITS question
  # is done, a whole-card slide until the card settles.
  defp pending_keys(slides) do
    slides
    |> Enum.filter(fn
      %{kind: :finished, item_id: id} ->
        match?(%{status: :open}, Loopyard.Notifications.get(id))

      slide ->
        case live_msg(slide) do
          %{status: :pending} = msg ->
            is_nil(slide.q_id) or slide.q_id not in (msg[:done] || [])

          _ ->
            false
        end
    end)
    |> MapSet.new(& &1.key)
  end

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
    cards =
      assigns.slides
      |> Enum.map(&resolve_card/1)
      |> Enum.reject(&is_nil/1)

    assigns = assign(assigns, :cards, cards)

    ~H"""
    <.notifications_deck
      cards={@cards}
      target={@target}
      advance_from={@advance_from}
      history?={@history?}
      threads={@threads}
      queued={@queued}
      operator_status={@operator_status}
      streaming={@streaming}
      awaiting={@awaiting}
      operator_id={@operator_id}
      user_label={@user_label}
      vapid_key={@vapid_key}
    />
    """
  end

  @doc """
  The deck itself, pure: everything below the card-resolution seam.
  `render/1` resolves slides to live messages (ETS) and hands the result
  here; the showcase `reviewer` scene calls this directly with mock cards.
  """
  attr :cards, :list, required: true
  attr :target, :any, default: nil, doc: "slide key to open at"
  attr :advance_from, :any, default: nil, doc: "slide key that just settled — move on from it"
  attr :history?, :boolean, default: false
  attr :threads, :map, default: %{}
  attr :queued, :map, default: %{}
  attr :operator_status, :atom, default: nil
  attr :streaming, :string, default: ""
  attr :awaiting, :any, default: nil
  attr :operator_id, :string, default: nil
  attr :user_label, :string, default: "You"
  attr :vapid_key, :string, default: nil

  def notifications_deck(assigns) do
    assigns = assign(assigns, :total, length(assigns.cards))

    ~H"""
    <AppShell.shell title="Notifications" mode={:notifications} mode_id="mode-notifications">
      <div class="flex-1 min-w-0 min-h-0 flex flex-col">
        <%!-- PAST decisions is the same deck with a different source; one quiet
      line says so, and the way back to the pending ones. --%>
        <div
          :if={@history?}
          class="flex-none flex items-center gap-3 px-4 md:px-6 min-h-11 text-meta text-zinc-500 dark:text-zinc-400 border-b border-zinc-200 dark:border-zinc-800"
        >
          <span class="font-medium text-zinc-700 dark:text-zinc-200">Past decisions</span>
          <.link
            navigate="/notifications"
            class="ml-auto text-violet-600 dark:text-violet-400 hover:underline"
          >
            ← Back to pending
          </.link>
        </div>
        <%!-- THE DECK: a horizontal scroll-snap carousel, one decision per slide,
      swiped with the browser's own scrolling (no JS gestures — nothing that
      competes with iOS back). `overscroll-x-contain` stops the rubber band
      at the ends. Each slide is its OWN vertical scroller with its own top
      bar, so the title (who's asking) travels with the swipe. There is
      deliberately no page-level bar above the slides: two bars was one too
      many, and the arrows in the lower one were too short to tap. --%>
        <div
          :if={@cards != []}
          id="decisions-deck"
          class="flex-1 min-h-0 flex overflow-x-auto overflow-y-hidden snap-x snap-mandatory overscroll-x-contain"
        >
          <Slide.decision_slide
            :for={{card, idx} <- Enum.with_index(@cards, 1)}
            card={card}
            index={idx}
            total={@total}
            prev={Enum.at(@cards, idx - 2)}
            next={Enum.at(@cards, idx)}
            target?={card.slide.key == @target}
            advance?={card.slide.key == @advance_from}
            thread={Map.get(@threads, {card.slide.agent_id, card.slide.msg_id}, [])}
            queued={Map.get(@queued, {card.slide.agent_id, card.slide.msg_id}, [])}
            operator_status={@operator_status}
            streaming={(@awaiting == {card.slide.agent_id, card.slide.msg_id} && @streaming) || ""}
            operator_id={@operator_id}
            user_label={@user_label}
          />
          <Slide.end_slide history?={@history?} last={List.last(@cards)} vapid_key={@vapid_key} />
        </div>

        <%!-- Nothing on the deck: the "you're done" beat, with the one bar it needs. --%>
        <div :if={@cards == []} class="flex-1 flex flex-col min-h-0">
          <div class="flex-1 flex flex-col items-center justify-center gap-4 py-24">
            <p class="text-body text-zinc-400 dark:text-zinc-500">
              {(@history? && "No decisions asked yet.") || "Nothing waiting on you."}
            </p>
            <.link
              :if={!@history?}
              navigate="/notifications/history"
              class="text-body font-medium inline-flex items-center min-h-11 md:min-h-0 text-violet-600 dark:text-violet-400 hover:underline"
            >
              Past decisions →
            </.link>
            <Slide.push_bell :if={!@history?} vapid_key={@vapid_key} />
          </div>
        </div>
      </div>
    </AppShell.shell>
    """
  end

  # A slide plus its LIVE message and (for a multi-question ask) the one
  # question this card is. Nil when the message has gone — a deleted agent
  # shouldn't leave a hole that crashes the deck.
  defp resolve_card(%{kind: :finished, item_id: id} = slide) do
    case Loopyard.Notifications.get(id) do
      %{} = item -> %{slide: slide, msg: nil, q: nil, item: item, dom_id: Deck.dom_id(slide)}
      _ -> nil
    end
  end

  defp resolve_card(slide) do
    case live_msg(slide) do
      %{} = msg ->
        %{
          slide: slide,
          msg: msg,
          q: slide.q_id && Enum.find(msg[:questions] || [], &(&1.id == slide.q_id)),
          item: slide[:item_id] && Loopyard.Notifications.get(slide.item_id),
          dom_id: Deck.dom_id(slide)
        }

      _ ->
        nil
    end
  end
end
