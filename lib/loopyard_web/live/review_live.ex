defmodule LoopyardWeb.ReviewLive do
  @moduledoc """
  `/decisions` — every decision waiting on you, one DECK you swipe through
  (plans/decisions.md). A multi-question ask fans out into one slide per
  question; approvals and secrets are one slide each. Newest first. Live:
  leave it open and new decisions join as agents ask.

  **Two axes, both native scrolling, no JS gestures.** The deck is a
  horizontal CSS scroll-snap carousel: swipe left/right to move between
  decisions. Each slide is its own vertical scroller: the decision at the
  top, its discussion below. Scroll into the discussion and the card
  COLLAPSES into a sticky orange header (who asked + the question, tap to
  pop back up) — the `StickyShadow` hook flips `data-stuck`; CSS does the
  rest.

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
    slides = if history?, do: history_slides(), else: slides(scope)

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

  # PAST decisions: every question/approval/secret ever asked (recent tail per
  # agent), any status, newest first — one slide per CARD.
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
        do: history_slides(),
        else: slides(socket.assigns.scope)

    socket
    |> assign(:slides, merge_deck(socket.assigns.slides, fresh))
    |> sync_secret_scope()
    |> subscribe_slides()
  end

  # Everything already on screen, in the order it was already in, plus whatever
  # is new — new ones go FIRST (newest first), which is the start of the deck,
  # never the middle of it.
  defp merge_deck(shown, fresh) do
    seen = MapSet.new(shown, & &1.key)
    Enum.reject(fresh, &MapSet.member?(seen, &1.key)) ++ shown
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
    assigns =
      assign(assigns,
        pending_count: Enum.count(assigns.cards, &(&1.msg.status == :pending)),
        total: length(assigns.cards)
      )

    ~H"""
    <div class="h-screen flex flex-col bg-brand-paper dark:bg-brand-ink text-zinc-900 dark:text-zinc-100 safe-area-x safe-area-top">
      <Nav.bar height="h-14" pad="px-2 md:px-4" gap="gap-2">
        <Nav.back_button navigate="/operator" label="Back to the operator" />
        <h1 class="min-w-0 truncate text-lead font-semibold">
          {(@history? && "Past decisions") || "Decisions"}
          <span
            :if={!@history? && @pending_count > 0}
            class="font-normal text-zinc-500 dark:text-zinc-400"
          >
            · {@pending_count} waiting
          </span>
        </h1>
        <:actions>
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
          <Common.mode_nav id="mode-decisions" active={:operator} />
        </:actions>
      </Nav.bar>

      <%!-- THE DECK: a horizontal scroll-snap carousel, one decision per slide,
      swiped with the browser's own scrolling (no JS gestures — nothing that
      competes with iOS back). `overscroll-x-contain` stops the rubber band
      at the ends. Each slide is its OWN vertical scroller: the decision on
      top, its discussion below. --%>
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
      </div>

      <%!-- Nothing on the deck: the "you're done" beat. --%>
      <div :if={@cards == []} class="flex-1 flex flex-col items-center justify-center gap-4 py-24">
        <p class="text-body text-zinc-400 dark:text-zinc-500">
          {(@history? && "No decisions asked yet.") || "Nothing waiting on you."}
        </p>
        <.link
          :if={!@history?}
          navigate="/decisions/history"
          class="text-body font-medium inline-flex items-center min-h-11 md:min-h-0 text-violet-600 dark:text-violet-400 hover:underline"
        >
          Flip through past decisions →
        </.link>
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

  # One decision: a full-width, full-height slide. The header is sticky INSIDE
  # the slide's scroller; the `StickyShadow` hook on the slide sets
  # `data-stuck` on it the moment the card has scrolled under it, and the
  # header grows the question (orange, tap → back to the top). That's the
  # "collapse the decision into a turn card" — one attribute, CSS states.
  defp decision_slide(assigns) do
    assigns =
      assign(assigns,
        ref: "#{assigns.card.slide.agent_id}:#{assigns.card.slide.msg_id}",
        prompt: card_prompt(assigns.card),
        pending?: assigns.card.msg.status == :pending,
        awaiting?: awaiting_reply?(assigns.thread),
        blocked?: operator_blocked?(assigns.operator_id, assigns.card)
      )

    ~H"""
    <section
      id={"slide-" <> @card.dom_id}
      phx-hook="StickyShadow"
      phx-mounted={@target? && JS.focus()}
      tabindex="-1"
      class="w-full h-full flex-none snap-start snap-always overflow-y-auto overscroll-y-contain focus:outline-none"
    >
      <div class="mx-auto w-full max-w-2xl">
        <%!-- Sticky header = who's asking, at rest. STUCK (card scrolled under
        it) = the collapsed decision: the question in an orange band. A
        real link back to the slide's top, so "tap to expand" is just a
        scroll. --%>
        <header
          data-sticky-header
          class={[
            "group sticky top-0 z-10 bg-brand-paper dark:bg-brand-ink border-b border-transparent",
            "data-[stuck]:border-orange-200 dark:data-[stuck]:border-orange-500/30",
            "data-[stuck]:shadow-[0_5px_6px_-6px_rgba(0,0,0,0.28)]"
          ]}
        >
          <div class="flex items-center gap-2 min-w-0 px-4 md:px-6 min-h-11 text-meta text-zinc-500 dark:text-zinc-400">
            <span
              aria-hidden="true"
              class={[
                "flex-none w-2 h-2 rounded-full",
                Common.state_light((@pending? && :needs_you) || :asleep)
              ]}
            ></span>
            <span class="min-w-0 truncate">
              Asked by
              <span class="font-medium text-zinc-700 dark:text-zinc-200">
                {@card.slide.agent_name || "Operator"}
              </span>
              <span :if={
                @card.slide.project_name && @card.slide.project_name != @card.slide.agent_name
              }>
                in {@card.slide.project_name}<span :if={@card.slide.workspace_name}> · {@card.slide.workspace_name}</span>
              </span>
              <span :if={@card.slide.asked_at}> · {ago(@card.slide.asked_at)}</span>
            </span>
            <span class="ml-auto flex-none inline-flex items-center gap-1 tabular-nums">
              <a
                :if={@prev}
                href={"#slide-" <> @prev.dom_id}
                aria-label="Previous decision"
                class="focus-ring tap-target inline-flex items-center justify-center w-7 h-7 rounded-sm hover:bg-zinc-100 dark:hover:bg-zinc-800"
              >
                ‹
              </a>
              {@index} of {@total}
              <a
                :if={@next}
                href={"#slide-" <> @next.dom_id}
                aria-label="Next decision"
                class="focus-ring tap-target inline-flex items-center justify-center w-7 h-7 rounded-sm hover:bg-zinc-100 dark:hover:bg-zinc-800"
              >
                ›
              </a>
            </span>
          </div>
          <a
            href={"#slide-" <> @card.dom_id}
            class="hidden group-data-[stuck]:flex items-center gap-3 px-4 md:px-6 py-2 border-l-4 border-orange-500 bg-orange-50 dark:bg-orange-500/10 text-body text-zinc-800 dark:text-zinc-100"
          >
            <span class="min-w-0 flex-1 line-clamp-2">{@prompt}</span>
            <span class="flex-none text-meta font-semibold text-orange-700 dark:text-orange-400">
              {(@pending? && "Answer ↑") || "↑"}
            </span>
          </a>
        </header>

        <div class="px-4 md:px-6 pt-2 pb-4">
          <%!-- ONE question of a multi-question ask is a bare block, so it
          needs the band around it. A whole card (approval, secret, a
          settled question receipt) already IS a band. No eyebrow on a
          pending one — the page is called Decisions and the header says
          who's asking; a settled one earns its "Answered" so a receipt
          can't be mistaken for a live ask. --%>
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

            <%!-- No chat_path: the card's "Chat" button navigated AWAY from the
            decision to the source agent's chat. Discussion happens here. --%>
            <Cards.question_block msg={@card.msg} q={@card.q} />
          </LoopyardWeb.Components.StreamCard.band>

          <Cards.question_card
            :if={is_nil(@card.q) && @card.msg.role == :question}
            msg={@card.msg}
          />
          <Cards.approval_card :if={@card.msg.role == :approval} msg={@card.msg} />
          <Cards.secret_card :if={@card.msg.role == :secret_request} msg={@card.msg} />

          <div class="mt-2 flex flex-wrap items-center gap-x-4">
            <.link
              :if={@card.slide.path}
              navigate={@card.slide.path}
              class="text-meta inline-flex items-center min-h-11 md:min-h-0 text-zinc-400 dark:text-zinc-500 hover:text-violet-600 dark:hover:text-violet-400"
            >
              Source chat →
            </.link>
          </div>

          <%!-- THE DISCUSSION — scroll down into it and the decision collapses
          into the header above. --%>
          <div id={"thread-" <> @card.dom_id} class="pt-6">
            <div class="section-label px-1 pb-1">About this decision</div>

            <p
              :if={@thread == [] and !@blocked?}
              class="px-1 py-2 text-body text-zinc-500 dark:text-zinc-400"
            >
              Ask the operator anything about this — what an option changes, what
              led here, what it would mean in the code. The decision stays put.
            </p>

            <p :if={@blocked?} class="px-1 py-2 text-body text-zinc-500 dark:text-zinc-400">
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

        <%!-- The slide's own composer, pinned to the slide's bottom. Same
        ChatForm hook as every chat (ack-gated clear, kept-on-failure);
        `data-re` names the decision so the send is tagged to it. --%>
        <div class="sticky bottom-0 px-4 md:px-6 pt-2 pb-[max(0.5rem,env(safe-area-inset-bottom))] bg-brand-paper dark:bg-brand-ink border-t border-zinc-200 dark:border-zinc-800">
          <div id={"composer-" <> @card.dom_id} phx-update="ignore">
            <form
              id={"chat-form-" <> @card.dom_id}
              phx-submit="send_message"
              phx-hook="ChatForm"
              data-re={@ref}
              class="flex items-end gap-2"
            >
              <textarea
                name="message"
                id={"chat-input-" <> @card.dom_id}
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
            <p data-send-status class="hidden mt-1.5 text-lead text-red-500 dark:text-red-400"></p>
          </div>
        </div>
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

  # The question's own words, for the collapsed header.
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
