defmodule LoopyardWeb.NotificationsLive.Slide do
  @moduledoc """
  One item's slide on the deck (`LoopyardWeb.NotificationsLive`): the byline,
  the card (a decision's, or a finished turn's — Keep going / Open /
  Dismiss), the collapsing band, the discussion thread and the composer —
  plus the end slide past the last item. Function components only; the
  LiveView owns the state and hands each slide its card, thread and queue.
  """
  use Phoenix.Component

  alias Brand
  alias Loopyard.ChatAgent
  alias LoopyardWeb.Components.Common
  alias LoopyardWeb.Live.WorkspaceLive.Messages
  alias LoopyardWeb.Live.WorkspaceLive.Messages.Cards
  alias LoopyardWeb.NotificationsLive.Deck
  alias Phoenix.LiveView.JS

  attr :card, :map, required: true
  # nil = this slide is settled: it keeps its place on the deck but is not one
  # of the things still waiting, so it carries no position.
  attr :index, :integer, default: nil
  attr :total, :integer, default: 0
  attr :prev, :map, default: nil
  attr :next, :map, default: nil
  attr :target?, :boolean, default: false
  attr :advance?, :boolean, default: false
  attr :thread, :list, default: []
  attr :queued, :list, default: []
  attr :operator_status, :atom, default: nil
  attr :streaming, :string, default: ""
  attr :operator_id, :string, default: nil
  attr :user_label, :string, required: true

  # One decision: a full-width, full-height slide with its own top bar. The
  # bar names who's asking (the title), where you are in the deck, and the
  # neighbours — every control a full 44px. Below it the card; below that the
  # discussion, whose sticky header becomes the collapsed card (orange band)
  # once the card has scrolled away — the slide's `StickyShadow` hook sets
  # `data-stuck`, CSS switches the look. The composer is pinned to the foot.
  def decision_slide(assigns) do
    finished? = assigns.card.slide.kind == :finished
    item = assigns.card[:item]

    assigns =
      assign(assigns,
        ref: "#{assigns.card.slide.agent_id}:#{assigns.card.slide.msg_id}",
        finished?: finished?,
        item: item,
        prompt: (finished? && item && item.label) || card_prompt(assigns.card),
        # ONE predicate for "still waiting", shared with the deck's count — a
        # question of a multi-question ask resolves on its own, so asking the
        # message left an answered question wearing the flame.
        pending?: Deck.pending_card?(assigns.card),
        verb: (finished? && "finished") || "asked",
        awaiting?: awaiting_reply?(assigns.thread),
        blocked?: operator_blocked?(assigns.operator_id, assigns.card),
        who: Deck.who_asked(assigns.card.slide),
        system_source?: Deck.system?(assigns.card.slide)
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
        class="isolate overscroll-y-contain flex-1 min-h-0 overflow-y-auto"
      >
        <div class="mx-auto w-full max-w-2xl px-4 md:px-6 pt-6">
          <div id={"top-" <> @card.dom_id}></div>
          <%!-- One-shot: mounts only while this slide is the one that just
        settled; focusing the next slide scrolls the deck to it. --%>
          <span
            :if={@advance?}
            id={"advance-" <> @card.dom_id}
            phx-mounted={JS.focus(to: (@next && "#slide-" <> @next.dom_id) || "#slide-end")}
            class="hidden"
          ></span>
          <%!-- WHO'S ASKING, as content — not chrome. "From the Operator · 21d
        ago" with "8 of 11" opposite, in the same calm meta voice as the rest
        of the card, so it flicks with the decision instead of looking like a
        second bar that flicks. The one bar that stays put says Decisions. --%>
          <%!-- THE BYLINE. Who's asking, wearing their own mark: the operator is the
        trefoil (the brand mark is its face); a workspace agent is its
        project · workspace identity, then its name. Age in words. Position
        as "n of N" — a row of dots was tried and read as noise; the number
        is what you actually want to know. --%>
          <div class="flex items-center gap-2 min-w-0 mb-3 text-lead text-zinc-500 dark:text-zinc-400">
            <span
              :if={@system_source?}
              class={[
                "flex-none",
                (@pending? && "text-orange-500") || "text-zinc-400 dark:text-zinc-500"
              ]}
              aria-hidden="true"
            >
              <Brand.mark class="w-5 h-5" />
            </span>
            <%!-- The byline is the way BACK TO THE CONVERSATION: a decision is a
            moment in a chat, and the chat is where the reasoning around it
            lives. The anchor names the card's own message, so a chat that has
            it on screen lands on it. --%>
            <.link
              :if={@system_source?}
              navigate={"#{@card.slide.path}#msg-#{@card.slide.msg_id}"}
              class="min-w-0 truncate hover:underline"
            >
              <span class="font-semibold text-zinc-800 dark:text-zinc-100">
                {@card.slide.agent_name || "System"}
              </span>
              <span :if={@card.slide.asked_at}>{@verb} {Deck.ago_words(@card.slide.asked_at)}</span>
            </.link>
            <%!-- A workspace agent's byline: a whole CARD wears the project ·
            workspace chip itself (the same chip twice, two lines apart, was
            the junk), so the byline is a state light and the name. A bare
            question of a fanned-out ask has no card header, so its byline
            carries the chip. --%>
            <.link
              :if={!@system_source?}
              navigate={"#{@card.slide.path}#msg-#{@card.slide.msg_id}"}
              class="min-w-0 flex items-center gap-2 truncate hover:underline"
            >
              <Common.workspace_identity
                :if={@card.q}
                project={@card.slide.project_name}
                workspace={@card.slide.workspace_name}
                state={(@pending? && ((@finished? && :done) || :needs_you)) || :asleep}
                class="min-w-0"
              />
              <span
                :if={!@card.q}
                class={[
                  "flex-none w-2 h-2 rounded-full",
                  Common.state_light((@pending? && ((@finished? && :done) || :needs_you)) || :asleep)
                ]}
                aria-hidden="true"
              ></span>
              <span class="truncate">
                <span :if={@card.q}>· </span>
                <span class="font-semibold text-zinc-800 dark:text-zinc-100">{@card.slide.agent_name}</span>
                <span :if={@card.slide.asked_at}>{@verb} {Deck.ago_words(@card.slide.asked_at)}</span>
              </span>
            </.link>
            <span class="ml-auto flex-none inline-flex items-center gap-1 text-meta tabular-nums whitespace-nowrap">
              <a
                :if={@prev}
                href={"#slide-" <> @prev.dom_id}
                aria-label="Previous decision"
                class="focus-ring tap-target hidden md:inline-flex items-center justify-center w-7 h-7 rounded-sm hover:bg-zinc-100 dark:hover:bg-zinc-800"
              >
                ‹
              </a>
              <%!-- The SAME slot holds the position while it waits and the
              outcome once it is settled, so answering swaps a word instead of
              inserting a row and shoving the question down the screen. --%>
              <span :if={@index}>{@index} of {@total}</span>
              <span :if={!@index} class="uppercase tracking-wide font-semibold">
                {settled_word(@card)}
              </span>
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
        question receipt) already IS a band. No eyebrow, and no "Answered"
        header on settling: adding a row above the question moved the
        question itself down the screen at the exact moment you had just
        read it. The outcome is a word in the bar; the chosen option turns
        green and the buttons go. --%>
          <LoopyardWeb.Components.StreamCard.band
            :if={@card.q}
            tone={(@pending? && :needs_you) || :neutral}
            chrome={:desktop}
          >
            <Cards.question_block msg={@card.msg} q={@card.q} show_header={false} />
          </LoopyardWeb.Components.StreamCard.band>

          <%!-- Settled, and another decision is waiting: the way on, where the
          buttons used to be. Without it a settled slide is a dead end you
          have to swipe out of. --%>
          <.link
            :if={!@pending? && @next}
            href={"#slide-" <> @next.dom_id}
            class={[
              "mt-4 w-full sm:w-auto",
              LoopyardWeb.Components.StreamCard.action_class(variant: :primary, tone: :confirm)
            ]}
          >
            Next decision →
          </.link>

          <Cards.question_card
            :if={!@finished? && is_nil(@card.q) && @card.msg.role == :question}
            msg={@card.msg}
          />
          <Cards.approval_card :if={!@finished? && @card.msg.role == :approval} msg={@card.msg} />
          <Cards.secret_card
            :if={!@finished? && @card.msg.role == :secret_request}
            msg={@card.msg}
          />
          <.finished_card :if={@finished? && @item} item={@item} pending?={@pending?} />

          <%!-- THE COLLAPSED DECISION. Nothing at rest. Placed AFTER the card and
        sticky under the bar, it pins exactly when the card has scrolled
        away, and only then (data-stuck) shows the question in an orange
        band — a real link back to the top, so "tap to expand" is just a
        scroll. Pure sticky placement decides WHEN; one attribute decides
        the LOOK. --%>
          <div
            data-sticky-header
            class="group sticky -top-px pt-px z-10 -mx-4 md:-mx-6 mt-4 bg-brand-paper dark:bg-brand-ink"
          >
            <%!-- Big enough to read AND to hit: two lines of the question at
          chat size, a full-height row, and a filled Answer chip — this is
          the way back to the decision while the thread flies under it. --%>
            <a
              href={"#top-" <> @card.dom_id}
              class="hidden group-data-[stuck]:block px-4 md:px-6 py-3 border-l-4 border-orange-500 bg-orange-50 dark:bg-orange-500/10 text-zinc-900 dark:text-zinc-50 shadow-[0_5px_6px_-6px_rgba(0,0,0,0.28)]"
            >
              <%!-- Byline top-left, one round "back up" top-right, then the
              question under both at chat size, four lines at most — it was
              ten lines tall with a chip beside three lines of text. --%>
              <span class="flex items-center gap-3">
                <span class="min-w-0 flex-1 truncate text-meta text-zinc-500 dark:text-zinc-400">
                  From {@who}<span :if={@card.slide.asked_at}> · {Deck.ago(@card.slide.asked_at)}</span>
                  <span :if={@index}>· {@index} of {@total}</span>
                </span>
                <span
                  aria-label="Back to the decision"
                  class="flex-none inline-flex items-center justify-center w-9 h-9 rounded-full bg-orange-600 text-white text-lead"
                >
                  ↑
                </span>
              </span>
              <span class="mt-1 line-clamp-4 text-lead">{@prompt}</span>
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
              This is {@card.slide.agent_name || "the agent"}'s own question, and it's
              waiting on your answer before it can do anything else — including
              discuss it. Answer it above, or ask in a moment: anything you send
              now is queued until it's free.
            </p>

            <div :for={{msg, idx} <- Enum.with_index(@thread)} :key={msg[:id] || idx}>
              <Messages.chat_msg
                msg={msg}
                idx={idx}
                messages={@thread}
                agent_id={@operator_id || @card.slide.agent_id}
                host="localhost"
                detail_level={:chat}
                user_label={@user_label}
                sticky?={false}
              />
            </div>

            <%!-- Parked sends, shown where they were sent from: the operator
            was busy, so this waits in its queue and goes out when it's
            free. Without this the message vanished until it drained. --%>
            <div
              :for={text <- @queued}
              class="mt-3 px-3 py-2 border-l-2 border-violet-400/60 bg-violet-500/5 text-lead text-zinc-700 dark:text-zinc-300"
            >
              <span class="block text-meta text-violet-600 dark:text-violet-400">
                Queued — the agent is busy; this sends when it's free
              </span>
              {text}
            </div>

            <div :if={@streaming != ""} class="px-1 py-2 text-lead whitespace-pre-wrap">
              {@streaming}
            </div>
            <p
              :if={(@awaiting? or @queued != []) and @streaming == "" and !@blocked?}
              class="px-1 py-2 text-body text-zinc-400 dark:text-zinc-500"
            >
              {waiting_line(@operator_status)}
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
          <%!-- OPTIMISTIC ECHO: the instant you hit Send, the ChatForm hook shows
          your words here as "Sending…" — the operator may be mid-turn and
          park the message for a while, and a send with nothing on screen
          read as "nothing is going through". The server's queued band or
          the message itself replaces it on the ack. --%>
          <div
            data-send-echo
            class="hidden mb-2 px-3 py-2 border-l-2 border-violet-400/60 bg-violet-500/5 text-lead text-zinc-700 dark:text-zinc-300"
          >
            <div data-echo-label class="text-meta text-violet-600 dark:text-violet-400">Sending…</div>
            <div data-echo-text class="whitespace-pre-wrap line-clamp-3"></div>
          </div>
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
              placeholder={
                (@finished? && "Tell #{@card.slide.agent_name} what's next…") ||
                  "Chat about this decision…"
              }
              aria-label={(@finished? && "What's next") || "Chat about this decision"}
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

  attr :item, :map, required: true
  attr :pending?, :boolean, required: true

  # A FINISHED turn: what the agent said last, the ±N of changes, and the
  # three moves — Keep going (the move the item exists for: filled, moss,
  # since nothing is blocked), Open (the agent's chat), Dismiss (furthest
  # away). Settled, it reads as a receipt so the deck can stay sticky.
  defp finished_card(assigns) do
    assigns = assign(assigns, :changes, assigns.item.meta[:changes])

    ~H"""
    <LoopyardWeb.Components.StreamCard.band tone={:neutral} chrome={:desktop}>
      <div class="flex items-center gap-2 text-meta font-semibold uppercase tracking-wide">
        <span class={
          (@pending? && "text-emerald-600 dark:text-emerald-400") ||
            "text-zinc-500 dark:text-zinc-400"
        }>
          {finished_word(@item)}
        </span>
        <span
          :if={@changes && @changes.added + @changes.removed > 0}
          class="normal-case tracking-normal tabular-nums text-zinc-500 dark:text-zinc-400"
        >
          · <span class="text-emerald-600 dark:text-emerald-400">+{@changes.added}</span>
          <span class="text-red-500 dark:text-red-400">−{@changes.removed}</span> uncommitted
        </span>
      </div>
      <p class="mt-2 text-lead text-zinc-900 dark:text-zinc-50">{@item.label}</p>

      <div :if={@pending?} class="mt-4 flex flex-col sm:flex-row sm:items-center gap-2">
        <button
          type="button"
          phx-click="keep_going"
          phx-value-id={@item.id}
          class={LoopyardWeb.Components.StreamCard.action_class(variant: :primary, tone: :confirm)}
        >
          Keep going
        </button>
        <.link navigate={@item.path} class={LoopyardWeb.Components.StreamCard.action_class()}>
          Open
        </.link>
        <button
          type="button"
          phx-click="dismiss_item"
          phx-value-id={@item.id}
          class={[LoopyardWeb.Components.StreamCard.action_class(), "sm:ml-auto"]}
        >
          Dismiss
        </button>
      </div>
      <p :if={!@pending?} class="mt-3 text-lead text-zinc-500 dark:text-zinc-400">
        {finished_receipt(@item)}
      </p>
    </LoopyardWeb.Components.StreamCard.band>
    """
  end

  defp finished_word(%{status: :open}), do: "Finished"
  defp finished_word(%{status: :settled, outcome: :kept_going}), do: "Kept going"
  defp finished_word(%{status: :settled, outcome: :resumed}), do: "Back at it"
  defp finished_word(%{status: :dismissed}), do: "Dismissed"
  defp finished_word(_), do: "Settled"

  defp finished_receipt(%{status: :settled, outcome: :kept_going, agent_name: a}),
    do: "Kept going — #{a} is on it."

  defp finished_receipt(%{status: :settled, outcome: :resumed, agent_name: a}),
    do: "#{a} picked the work back up on its own."

  defp finished_receipt(%{status: :dismissed}), do: "Dismissed — nothing more to do here."
  defp finished_receipt(_), do: "Settled."

  attr :vapid_key, :string, default: nil

  @doc """
  Push for THIS device: one tap subscribes (the `PushBell` hook owns the
  permission + subscription), and, once on, a checkbox adds finished turns
  to what it rings for. Rendered where the deck rests — the empty state and
  the end slide — never in a bar.
  """
  def push_bell(assigns) do
    ~H"""
    <div
      :if={@vapid_key}
      id="push-bell"
      phx-hook="PushBell"
      phx-update="ignore"
      data-vapid={@vapid_key}
      class="mt-6 flex flex-col items-center gap-2 text-body text-zinc-500 dark:text-zinc-400"
    >
      <button
        type="button"
        data-bell-toggle
        class="focus-ring inline-flex items-center min-h-11 px-3 rounded-sm hover:bg-zinc-100 dark:hover:bg-zinc-800 hover:text-violet-600 dark:hover:text-violet-400 transition-colors"
      >
        <span data-bell-label>Notify this device about decisions</span>
      </button>
      <label data-bell-finished-wrap class="hidden inline-flex items-center gap-2 min-h-11 px-3">
        <input type="checkbox" data-bell-finished class="rounded-sm" /> …and when agents finish a turn
      </label>
    </div>
    """
  end

  attr :history?, :boolean, default: false
  attr :last, :map, default: nil
  attr :vapid_key, :string, default: nil
  attr :waiting, :integer, default: 0, doc: "decisions still open behind this slide"
  attr :next_pending, :map, default: nil, doc: "the first one still waiting, to go back to"

  # The slide past the last decision: where the deck ends, and the way on.
  #
  # It used to claim "that's everything waiting on you" even with decisions
  # still open behind it — you swipe past a card you skipped and the app tells
  # you you're done while its own badge says two. And the links floated as a
  # loose centred pile: different widths, arrows on opposite sides, a full tap
  # target of air between them.
  def end_slide(assigns) do
    ~H"""
    <section
      id="slide-end"
      class="w-full h-full flex-none snap-start snap-always overflow-y-auto flex flex-col"
    >
      <div class="flex-1 flex flex-col items-center justify-center px-6">
        <div class="w-full max-w-xs flex flex-col items-stretch text-center">
          <p class="text-lead text-zinc-500 dark:text-zinc-400 mb-6">
            {end_line(@history?, @waiting)}
          </p>
          <%!-- One stack, one width, one edge: the actions read as a group
          instead of three things that happen to be centred. --%>
          <.link
            :if={@next_pending}
            href={"#slide-" <> @next_pending.dom_id}
            class="text-body font-semibold min-h-11 inline-flex items-center justify-center text-violet-600 dark:text-violet-400 hover:underline"
          >
            Go to the next one
          </.link>
          <.link
            navigate={(@history? && "/notifications") || "/notifications/history"}
            class="text-body font-medium min-h-11 inline-flex items-center justify-center text-violet-600 dark:text-violet-400 hover:underline"
          >
            {(@history? && "Back to pending") || "Past decisions"}
          </.link>
          <.link
            navigate="/"
            class="text-body min-h-11 inline-flex items-center justify-center text-zinc-500 dark:text-zinc-400 hover:underline"
          >
            Home
          </.link>
          <.push_bell :if={!@history?} vapid_key={@vapid_key} />
        </div>
      </div>
    </section>
    """
  end

  # What the operator is doing while you wait — the honest word, not a
  # generic spinner. A queued send while it's idle means it's about to take it.
  defp waiting_line(status) when status in [:booting, :starting, :restarting],
    do: "Waking the agent…"

  defp waiting_line(:compacting), do: "The agent is tidying its context first…"
  defp waiting_line(:rate_limited), do: "The agent is rate-limited — it retries on its own"
  defp waiting_line(_), do: "Working on it…"

  defp awaiting_reply?(thread) do
    case List.last(thread) do
      %{role: :user} -> true
      _ -> false
    end
  end

  # The question's own words, for the collapsed band.
  # What happened to this decision, for the bar. Mirrors the question card's
  # own vocabulary so a receipt reads the same wherever you meet it.
  defp end_line(true, _waiting), do: "That's every past decision."
  defp end_line(_history?, 0), do: "That's everything waiting on you."
  defp end_line(_history?, 1), do: "One decision is still waiting on you."
  defp end_line(_history?, n), do: "#{n} decisions are still waiting on you."

  defp settled_word(%{msg: %{status: status}}) do
    case status do
      :timeout -> "No answer"
      :retracted -> "Retracted"
      :dismissed -> "Dismissed"
      _ -> "Answered"
    end
  end

  defp settled_word(_), do: "Done"

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
end
