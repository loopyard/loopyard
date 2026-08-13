defmodule LoopyardWeb.ReviewLive do
  @moduledoc """
  `/review` — the Reviewer (plans/question-review.md): catch up on everything
  waiting on you, ONE decision per slide. A multi-question ask fans out into
  one slide per question; approvals and secrets are one slide each. Prev/next,
  a position indicator, and answer → settled beat → advance. Live: leave it
  open in a tab and new items join the line as agents ask.

  Built on the FOCUSED VIEW shell (`LoopyardWeb.Components.FocusedView`) — the
  subject (project · workspace) is prominent, the content sits alone at the
  reading measure. Sourced from `Loopyard.Attention.line/0` (durable,
  card-sourced), so nothing waiting can be missing. `?workspace=<id>` scopes to
  one workspace; `?q=<agent>:<msg>` starts at a specific item.

  The current slide is keyed `{agent_id, msg_id, q_id}` so queue churn never
  yanks the screen; when the current decision settles it holds for a beat
  (you see it take), then advances to the next pending slide.
  """
  use LoopyardWeb, :live_view

  alias Loopyard.Events
  alias LoopyardWeb.Components.FocusedView
  alias LoopyardWeb.Live.WorkspaceLive.Messages.Cards

  @tick_ms 3_000

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Events.Activity.subscribe_global()
      Process.send_after(self(), :tick, @tick_ms)
    end

    # Resource routes: /review · /review/:agent_id/:msg_id ·
    # /projects/:project_id/workspaces/:workspace_id/review.
    scope = params["workspace_id"]
    history? = socket.assigns.live_action == :history
    socket = socket |> assign(:scope, scope) |> assign(:history?, history?)
    slides = if history?, do: history_slides(), else: slides(scope)

    # A permalink names ONE decision, and that stays a single focused screen —
    # each card is a mini app you can hand someone. Bare /review is the DECK:
    # every decision on one scrollable page.
    focused =
      with aid when is_binary(aid) <- params["agent_id"],
           mid when is_binary(mid) <- params["msg_id"],
           %{} = slide <- Enum.find(slides, &(&1.agent_id == aid and &1.msg_id == mid)) do
        slide.key
      else
        _ -> nil
      end

    {:ok,
     socket
     |> assign(:focused?, not is_nil(focused))
     |> assign(:slides, slides)
     |> assign(:current, focused || first_key(slides))
     |> assign(:subscribed, MapSet.new())
     |> assign(:last_path, nil)
     |> LoopyardWeb.Live.ConsentUI.attach(secret_scope: scope)
     |> sync_secret_scope()
     |> track_current()}
  end

  # Answer updates are CASTS — the card flips via a MessageUpdated broadcast,
  # not synchronously with the click. Subscribe to the current slide's agent so
  # the settle renders the instant the update lands (no 3s tick latency). Also
  # remember the slide's chat path — it's where "done reviewing" returns to.
  defp track_current(socket) do
    # EVERY agent in the deck, not just one: all the cards are on screen at
    # once now, so a card whose agent we hadn't subscribed to would sit stale
    # until the 3s tick — visibly slower than the one you happened to be on.
    socket = Enum.reduce(socket.assigns.slides, socket, &subscribe_slide/2)

    case current_slide(socket) do
      %{} = slide -> assign(socket, :last_path, slide[:path] || socket.assigns.last_path)
      _ -> socket
    end
  end

  defp subscribe_slide(%{agent_id: aid}, socket) when is_binary(aid) do
    if connected?(socket) and not MapSet.member?(socket.assigns.subscribed, aid) do
      Events.ChatAgentMessage.subscribe(aid)
      assign(socket, :subscribed, MapSet.put(socket.assigns.subscribed, aid))
    else
      socket
    end
  end

  defp subscribe_slide(_, socket), do: socket

  # ── the slide deck ────────────────────────────────────────────────────────
  #
  # One slide per DECISION: each pending question of a multi-question ask is
  # its own slide; an approval or secret is one slide. Slides carry everything
  # the render needs except the live message (fetched fresh per render).

  defp slides(scope) do
    Loopyard.Attention.line()
    |> Enum.filter(&(is_nil(scope) or &1.workspace_id == scope))
    |> Enum.flat_map(&item_slides/1)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # The TIME MACHINE deck: every question/approval/secret ever asked (recent
  # tail per agent), any status, newest first — one slide per CARD (settled
  # receipts render whole). "We have them around anyway, so might as well."
  defp history_slides do
    ws_names =
      for p <- Loopyard.ProjectRegistry.list_projects(),
          ws <- Loopyard.WorkspaceRegistry.list_workspaces(p.id),
          into: %{} do
        {ws.id, %{project_name: p.name, workspace_name: ws.name, project_id: p.id}}
      end

    for %{id: aid} = st <- Loopyard.ChatAgent.list_agent_summaries(),
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
  # bursts. Coalesce: arm one delayed refresh instead of scanning per event
  # (the deck rarely changes; the scan isn't free).
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

  def handle_info(%Events.ChatAgentMessage.Message{}, socket), do: {:noreply, refresh(socket)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # The deck is STICKY: a decision that settles STAYS in the list, rendered as
  # its own receipt, and new ones append. Dropping it the instant it resolved
  # would delete a section from the middle of a page the user is scrolling —
  # everything below jumps up under their thumb, which is how you mis-tap the
  # next decision. Answering should change a card, not the page.
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
  # is new. Order is the contract — the deck must not reshuffle while read.
  defp merge_deck(shown, fresh) do
    seen = MapSet.new(shown, & &1.key)
    shown ++ Enum.reject(fresh, &MapSet.member?(seen, &1.key))
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
    Loopyard.ChatAgent.get_message(aid, mid)
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
    <.review_deck cards={@cards} focused?={@focused?} history?={@history?} />
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

  def review_deck(assigns) do
    assigns =
      assign(
        assigns,
        :pending_count,
        Enum.count(assigns.cards, &(&1.msg.status == :pending))
      )

    ~H"""
    <FocusedView.layout
      label={(@history? && "Time machine") || "Review"}
      position={@pending_count > 0 && "#{@pending_count} waiting"}
      mode={:operator}
      snap={!@focused?}
      crumbs={[{"Operator", "/operator"}]}
    >
      <:nav>
        <%!-- Flip between the pending deck and the TIME MACHINE (all past
    questions — they're durable anyway, so they're traversable). --%>
        <.link
          navigate={(@history? && "/review") || "/review/history"}
          class="focus-ring tap-target inline-flex items-center justify-center w-9 h-9 rounded-sm text-zinc-500 hover:bg-zinc-100 dark:hover:bg-zinc-800"
          aria-label={(@history? && "Back to pending") || "Question history"}
          title={(@history? && "Back to pending") || "Question history"}
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
      snap fights you the whole way down it, which is exactly when you're
      trying to reach the buttons at the bottom. Proximity gets out of the
      way mid-card and takes over at the boundaries. --%>
      <div class="space-y-10 md:space-y-16">
        <section :for={card <- @cards} id={"decision-" <> card.dom_id} class="snap-start scroll-mt-4">
          <FocusedView.subject
            project={card.slide.project_name || "Operator"}
            workspace={card.slide.workspace_name}
            state={(card.msg.status == :pending && :needs_you) || :asleep}
            context={subject_context(card.slide, card.msg)}
          />

          <%!-- ONE question of a multi-question ask is a bare block, so it needs
      the band + label around it. A whole card (approval, secret, a
      settled question receipt) already IS a band — wrapping it in
      another one nested two cards and printed the identity twice. --%>
          <LoopyardWeb.Components.StreamCard.band
            :if={card.q}
            tone={(card.msg.status == :pending && :needs_you) || :neutral}
            chrome={:desktop}
          >
            <%!-- No identity chip here: the subject right above already names
      project · workspace large — once is enough. --%>
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

            <Cards.question_block msg={card.msg} q={card.q} chat_path={card.slide.path} />
          </LoopyardWeb.Components.StreamCard.band>

          <Cards.question_card
            :if={is_nil(card.q) && card.msg.role == :question}
            msg={card.msg}
          />
          <Cards.approval_card :if={card.msg.role == :approval} msg={card.msg} />
          <Cards.secret_card :if={card.msg.role == :secret_request} msg={card.msg} />

          <%!-- The per-decision permalink. It stays a real URL because each card
      is its own mini app — the deck is the backlog, the link is the
      thing itself. --%>
          <div class="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1">
            <.link
              :if={!@focused?}
              navigate={"/review/#{card.slide.agent_id}/#{card.slide.msg_id}"}
              class="text-meta text-zinc-400 dark:text-zinc-500 hover:text-violet-600 dark:hover:text-violet-400"
            >
              Open this decision →
            </.link>
            <.link
              :if={card.slide.path}
              navigate={card.slide.path}
              class="text-meta text-zinc-400 dark:text-zinc-500 hover:text-violet-600 dark:hover:text-violet-400"
            >
              Open in chat for context →
            </.link>
          </div>
        </section>
      </div>

      <%!-- The END of the deck, not a dead end: when everything is settled this
      is the "you're done" beat. It replaced an automatic push_navigate that
      yanked the page away mid-scroll. --%>
      <div
        :if={@cards == [] || (@pending_count == 0 && !@history?)}
        class="flex flex-col items-center justify-center gap-4 py-24"
      >
        <p class="text-body text-zinc-400 dark:text-zinc-500">
          {cond do
            @history? -> "No questions asked yet."
            @cards == [] -> "Nothing waiting on you."
            true -> "All caught up."
          end}
        </p>
        <.link
          :if={!@history?}
          navigate="/review/history"
          class="text-body font-medium inline-flex items-center min-h-11 md:min-h-0 text-violet-600 dark:text-violet-400 hover:underline"
        >
          Flip through past questions →
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

  defp subject_context(%{agent_name: name, asked_at: %DateTime{} = at} = slide, _msg)
       when is_binary(name) do
    if slide[:project_name] in [nil, name] do
      "Asked #{ago(at)}"
    else
      "#{name} asked #{ago(at)}"
    end
  end

  defp subject_context(_, _), do: nil

  defp ago(at) do
    secs = DateTime.diff(DateTime.utc_now(), at)

    cond do
      secs < 60 -> "moments ago"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end
end
