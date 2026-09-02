defmodule LoopyardWeb.ReviewLive do
  @moduledoc """
  `/decisions` — every decision waiting on you, one DECK you swipe through
  (plans/decisions.md). A multi-question ask fans out into one slide per
  question; approvals and secrets are one slide each. Newest first. Live:
  leave it open and new decisions join as agents ask.

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

  Sourced from `Loopyard.Attention.line/0` (durable, card-sourced), so nothing
  waiting can be missing. `/projects/:p/workspaces/:w/decisions` scopes to one
  workspace. `/review*` routes are the old name and render the same thing.
  """
  use LoopyardWeb, :live_view

  alias Loopyard.{ChatAgent, Events}
  alias Loopyard.ChatAgent.Thread
  alias LoopyardWeb.Components.{Common, Nav}
  alias LoopyardWeb.Live.WorkspaceLive.Messages
  alias LoopyardWeb.Live.WorkspaceLive.Messages.Cards
  alias LoopyardWeb.ReviewLive.Deck
  alias Phoenix.LiveView.JS

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
     |> assign(:slides, slides)
     |> assign(:subscribed, MapSet.new())
     |> assign(:operator_id, operator_id)
     |> assign(:threads, %{})
     |> assign(:streaming, "")
     |> assign(:awaiting, nil)
     |> assign(:user_label, user_label(operator_id))
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

  def handle_info(_msg, socket), do: {:noreply, socket}

  # The deck is STICKY: a decision that settles STAYS, rendered as its own
  # receipt, and new ones join. Dropping a slide the instant it resolved would
  # shift every slide after it under the reader's thumb.
  defp refresh(socket) do
    fresh =
      if socket.assigns.history?,
        do: Deck.history(),
        else: Deck.pending(socket.assigns.scope)

    socket
    |> assign(:slides, Deck.merge(socket.assigns.slides, fresh))
    |> sync_secret_scope()
    |> subscribe_slides()
  end

  # ── the threads (talk about THIS decision) ───────────────────────────────

  # The operator's messages tagged to each decision on the deck, oldest first,
  # keyed by decision ref. One ETS read for all of them.
  defp load_threads(%{assigns: %{operator_id: op}} = socket) when is_binary(op) do
    threads =
      case ChatAgent.get_state(op) do
        %{messages: messages} when is_list(messages) ->
          messages
          |> Enum.filter(&match?({_, _}, &1[:re]))
          |> Enum.group_by(& &1[:re])

        _ ->
          %{}
      end

    assign(socket, :threads, threads)
  rescue
    _ -> assign(socket, :threads, %{})
  catch
    _, _ -> assign(socket, :threads, %{})
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
  def handle_event("send_message", %{"message" => text} = params, socket) do
    text = String.trim(text)

    with true <- text != "",
         {:ok, ref} <- parse_ref(params["re"]),
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

      _ ->
        {:reply, %{ok: true}, socket}
    end
  end

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
    <.review_deck
      cards={@cards}
      target={@target}
      history?={@history?}
      threads={@threads}
      streaming={@streaming}
      awaiting={@awaiting}
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
  attr :target, :any, default: nil, doc: "slide key to open at"
  attr :history?, :boolean, default: false
  attr :threads, :map, default: %{}
  attr :streaming, :string, default: ""
  attr :awaiting, :any, default: nil
  attr :operator_id, :string, default: nil
  attr :user_label, :string, default: "You"

  def review_deck(assigns) do
    assigns = assign(assigns, :total, length(assigns.cards))

    ~H"""
    <div class="h-screen flex flex-col bg-brand-paper dark:bg-brand-ink text-zinc-900 dark:text-zinc-100 safe-area-x safe-area-top">
      <%!-- THE one bar, and it stays put while the slides flick under it: what
      you're flipping through is Decisions. Who's asking lives IN each slide
      as content, so nothing that looks like navigation moves. --%>
      <Nav.bar height="h-14" pad="px-2 md:px-4" gap="gap-2">
        <Nav.back_button navigate="/operator" label="Back to the operator" />
        <h1 class="min-w-0 truncate text-lead font-semibold">
          {(@history? && "Past decisions") || "Decisions"}
        </h1>
        <:actions>
          <Common.mode_nav id="mode-decisions" active={:operator} />
        </:actions>
      </Nav.bar>

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
        <.decision_slide
          :for={{card, idx} <- Enum.with_index(@cards, 1)}
          card={card}
          index={idx}
          total={@total}
          prev={Enum.at(@cards, idx - 2)}
          next={Enum.at(@cards, idx)}
          target?={card.slide.key == @target}
          thread={Map.get(@threads, {card.slide.agent_id, card.slide.msg_id}, [])}
          streaming={(@awaiting == {card.slide.agent_id, card.slide.msg_id} && @streaming) || ""}
          operator_id={@operator_id}
          user_label={@user_label}
        />
        <.end_slide history?={@history?} last={List.last(@cards)} />
      </div>

      <%!-- Nothing on the deck: the "you're done" beat, with the one bar it needs. --%>
      <div :if={@cards == []} class="flex-1 flex flex-col min-h-0">
        <div class="flex-1 flex flex-col items-center justify-center gap-4 py-24">
          <p class="text-body text-zinc-400 dark:text-zinc-500">
            {(@history? && "No decisions asked yet.") || "Nothing waiting on you."}
          </p>
          <.link
            :if={!@history?}
            navigate="/decisions/history"
            class="text-body font-medium inline-flex items-center min-h-11 md:min-h-0 text-violet-600 dark:text-violet-400 hover:underline"
          >
            Past decisions →
          </.link>
        </div>
      </div>
    </div>
    """
  end

  attr :card, :map, required: true
  attr :index, :integer, required: true
  attr :total, :integer, required: true
  attr :prev, :map, default: nil
  attr :next, :map, default: nil
  attr :target?, :boolean, default: false
  attr :thread, :list, default: []
  attr :streaming, :string, default: ""
  attr :operator_id, :string, default: nil
  attr :user_label, :string, required: true

  # One decision: a full-width, full-height slide with its own top bar. The
  # bar names who's asking (the title), where you are in the deck, and the
  # neighbours — every control a full 44px. Below it the card; below that the
  # discussion, whose sticky header becomes the collapsed card (orange band)
  # once the card has scrolled away — the slide's `StickyShadow` hook sets
  # `data-stuck`, CSS switches the look. The composer is pinned to the foot.
  defp decision_slide(assigns) do
    assigns =
      assign(assigns,
        ref: "#{assigns.card.slide.agent_id}:#{assigns.card.slide.msg_id}",
        prompt: card_prompt(assigns.card),
        pending?: assigns.card.msg.status == :pending,
        awaiting?: awaiting_reply?(assigns.thread),
        blocked?: operator_blocked?(assigns.operator_id, assigns.card),
        who: Deck.who_asked(assigns.card.slide)
      )

    ~H"""
    <section
      id={"slide-" <> @card.dom_id}
      phx-mounted={@target? && JS.focus()}
      tabindex="-1"
      class="w-full h-full flex-none snap-start snap-always flex flex-col focus:outline-none"
    >
      <%!-- The slide is a COLUMN: this scroller, then the composer as a real
      footer. The composer used to be `sticky bottom-0` inside the scroller,
      and on iOS a sticky bottom travels with the rubber band — content
      showed through a gap under it. A flex footer is pinned by layout. --%>
      <div
        id={"scroll-" <> @card.dom_id}
        phx-hook="StickyShadow"
        class="flex-1 min-h-0 overflow-y-auto overscroll-y-contain"
      >
        <div class="mx-auto w-full max-w-2xl px-4 md:px-6 pt-3">
          <div id={"top-" <> @card.dom_id}></div>
          <%!-- WHO'S ASKING, as content — not chrome. "From the Operator · 21d
        ago" with "8 of 11" opposite, in the same calm meta voice as the rest
        of the card, so it flicks with the decision instead of looking like a
        second bar that flicks. The one bar that stays put says Decisions. --%>
          <div class="flex items-center gap-2 min-w-0 mb-3 text-meta text-zinc-500 dark:text-zinc-400">
            <span
              aria-hidden="true"
              class={[
                "flex-none w-2 h-2 rounded-full",
                Common.state_light((@pending? && :needs_you) || :asleep)
              ]}
            ></span>
            <span class="min-w-0 truncate">
              From <span class="font-medium text-zinc-700 dark:text-zinc-200">{@who}</span>
              <span :if={@card.slide.asked_at}> · {Deck.ago(@card.slide.asked_at)}</span>
            </span>
            <span class="ml-auto flex-none inline-flex items-center gap-1 tabular-nums whitespace-nowrap">
              <a
                :if={@prev}
                href={"#slide-" <> @prev.dom_id}
                aria-label="Previous decision"
                class="focus-ring tap-target hidden md:inline-flex items-center justify-center w-7 h-7 rounded-sm hover:bg-zinc-100 dark:hover:bg-zinc-800"
              >
                ‹
              </a>
              {@index} of {@total}
              <a
                href={(@next && "#slide-" <> @next.dom_id) || "#slide-end"}
                aria-label="Next decision"
                class="focus-ring tap-target hidden md:inline-flex items-center justify-center w-7 h-7 rounded-sm hover:bg-zinc-100 dark:hover:bg-zinc-800"
              >
                ›
              </a>
            </span>
          </div>
          <%!-- ONE question of a multi-question ask is a bare block, so it needs
        the band around it. A whole card (approval, secret, a settled
        question receipt) already IS a band. No eyebrow on a pending one and
        no per-question header label — the bar says who's asking and the
        question is alone on its slide; a settled one keeps "Answered" so a
        receipt can't be mistaken for a live ask. --%>
          <LoopyardWeb.Components.StreamCard.band
            :if={@card.q}
            tone={(@pending? && :needs_you) || :neutral}
            chrome={:desktop}
          >
            <LoopyardWeb.Components.StreamCard.header
              :if={!@pending?}
              state={:needs_you}
              label_class="text-zinc-500 dark:text-zinc-400"
            >
              <:label>Answered</:label>
            </LoopyardWeb.Components.StreamCard.header>

            <Cards.question_block msg={@card.msg} q={@card.q} show_header={false} />
          </LoopyardWeb.Components.StreamCard.band>

          <Cards.question_card
            :if={is_nil(@card.q) && @card.msg.role == :question}
            msg={@card.msg}
          />
          <Cards.approval_card :if={@card.msg.role == :approval} msg={@card.msg} />
          <Cards.secret_card :if={@card.msg.role == :secret_request} msg={@card.msg} />

          <%!-- THE COLLAPSED DECISION. Nothing at rest. Placed AFTER the card and
        sticky under the bar, it pins exactly when the card has scrolled
        away, and only then (data-stuck) shows the question in an orange
        band — a real link back to the top, so "tap to expand" is just a
        scroll. Pure sticky placement decides WHEN; one attribute decides
        the LOOK. --%>
          <div
            data-sticky-header
            class="group sticky top-0 z-10 -mx-4 md:-mx-6 mt-4 bg-brand-paper dark:bg-brand-ink"
          >
            <%!-- Big enough to read AND to hit: two lines of the question at
          chat size, a full-height row, and a filled Answer chip — this is
          the way back to the decision while the thread flies under it. --%>
            <a
              href={"#top-" <> @card.dom_id}
              class="hidden group-data-[stuck]:flex items-center gap-3 px-4 md:px-6 py-3 min-h-16 border-l-4 border-orange-500 bg-orange-50 dark:bg-orange-500/10 text-lead text-zinc-900 dark:text-zinc-50 shadow-[0_5px_6px_-6px_rgba(0,0,0,0.28)]"
            >
              <span class="min-w-0 flex-1 line-clamp-2">{@prompt}</span>
              <span class="flex-none inline-flex items-center min-h-11 px-3 rounded-sm bg-orange-600 text-white text-body font-semibold">
                {(@pending? && "Answer ↑") || "Back ↑"}
              </span>
            </a>
          </div>

          <%!-- THE DISCUSSION. It grows with its content and no further: a slide
        with no thread scrolls to the bottom of the card and stops (a screen
        of empty space under Dismiss read as broken). The collapsed band
        above only comes into play once a real thread is long enough to
        scroll the card away. Prompt bands are NOT sticky here — the slide
        has its own chrome. --%>
          <div id={"thread-" <> @card.dom_id} class="scroll-mt-24">
            <p :if={@blocked?} class="px-1 py-3 text-body text-zinc-500 dark:text-zinc-400">
              This is the operator's own question, and it's waiting on your answer
              before it can do anything else — including discuss it. Answer it
              above, or ask in a moment: anything you send now is queued until
              it's free.
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
                sticky?={false}
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
        </div>
      </div>

      <%!-- The slide's own composer, the slide's FOOTER — the one thing at the
      bottom of the screen, flush with it (the safe-area inset is its own
      padding). Same ChatForm hook as every chat (ack-gated clear,
      kept-on-failure); `data-re` names the decision so the send is tagged
      to it. --%>
      <div class="flex-none px-4 md:px-6 pt-2 pb-[max(0.5rem,env(safe-area-inset-bottom))] bg-brand-paper dark:bg-brand-ink border-t border-zinc-200 dark:border-zinc-800">
        <div id={"composer-" <> @card.dom_id} phx-update="ignore" class="mx-auto w-full max-w-2xl">
          <form
            id={"chat-form-" <> @card.dom_id}
            phx-submit="send_message"
            phx-hook="ChatForm"
            data-re={@ref}
            data-scroll-to={"thread-" <> @card.dom_id}
            class="flex items-end gap-2"
          >
            <textarea
              name="message"
              id={"chat-input-" <> @card.dom_id}
              rows="1"
              placeholder="Chat about this decision…"
              aria-label="Chat about this decision"
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
          <p data-send-status class="hidden mt-1.5 text-lead text-red-500 dark:text-red-400"></p>
        </div>
      </div>
    </section>
    """
  end

  attr :history?, :boolean, default: false
  attr :last, :map, default: nil

  # The slide past the last decision: where the deck ends, and the way to the
  # past ones. Swipe on from the last decision and you land here.
  defp end_slide(assigns) do
    ~H"""
    <section
      id="slide-end"
      class="w-full h-full flex-none snap-start snap-always overflow-y-auto flex flex-col"
    >
      <div class="flex-1 flex flex-col items-center justify-center gap-4 py-24 px-6">
        <p class="text-body text-zinc-400 dark:text-zinc-500">
          {(@history? && "That's every past decision.") || "That's everything waiting on you."}
        </p>
        <.link
          navigate={(@history? && "/decisions") || "/decisions/history"}
          class="text-body font-medium inline-flex items-center min-h-11 md:min-h-0 text-violet-600 dark:text-violet-400 hover:underline"
        >
          {(@history? && "← Back to pending") || "Past decisions →"}
        </.link>
        <.link
          navigate="/operator"
          class="text-body font-medium inline-flex items-center min-h-11 md:min-h-0 text-violet-600 dark:text-violet-400 hover:underline"
        >
          ← Back to the operator
        </.link>
      </div>
    </section>
    """
  end

  defp awaiting_reply?(thread) do
    case List.last(thread) do
      %{role: :user} -> true
      _ -> false
    end
  end

  # The question's own words, for the collapsed band.
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
          dom_id: Deck.dom_id(slide)
        }

      _ ->
        nil
    end
  end
end
