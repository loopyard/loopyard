defmodule LoopyardWeb.ReviewLive.Slide do
  @moduledoc """
  One decision's slide on the deck (`LoopyardWeb.ReviewLive`): the byline,
  the card, the collapsing band, the discussion thread and the composer —
  plus the end slide past the last decision. Function components only; the
  LiveView owns the state and hands each slide its card, thread and queue.
  """
  use Phoenix.Component

  alias Brand
  alias Loopyard.ChatAgent
  alias LoopyardWeb.Components.Common
  alias LoopyardWeb.Live.WorkspaceLive.Messages
  alias LoopyardWeb.Live.WorkspaceLive.Messages.Cards
  alias LoopyardWeb.ReviewLive.Deck
  alias Phoenix.LiveView.JS

  attr :card, :map, required: true
  attr :index, :integer, required: true
  attr :total, :integer, required: true
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
    assigns =
      assign(assigns,
        ref: "#{assigns.card.slide.agent_id}:#{assigns.card.slide.msg_id}",
        prompt: card_prompt(assigns.card),
        pending?: assigns.card.msg.status == :pending,
        awaiting?: awaiting_reply?(assigns.thread),
        blocked?: operator_blocked?(assigns.operator_id, assigns.card),
        who: Deck.who_asked(assigns.card.slide),
        operator_source?: Deck.operator?(assigns.card.slide)
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
        <div class="mx-auto w-full max-w-2xl px-4 md:px-6 pt-5">
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
        as a row of dots — the swipe affordance you can read at a glance —
        while the deck is short enough; "n of N" past that. --%>
          <div class="flex items-center gap-2 min-w-0 mb-1 text-lead text-zinc-500 dark:text-zinc-400">
            <span
              :if={@operator_source?}
              class={[
                "flex-none",
                (@pending? && "text-orange-500") || "text-zinc-400 dark:text-zinc-500"
              ]}
              aria-hidden="true"
            >
              <Brand.mark class="w-5 h-5" />
            </span>
            <span :if={@operator_source?} class="min-w-0 truncate">
              <span class="font-semibold text-zinc-800 dark:text-zinc-100">Operator</span>
              <span :if={@card.slide.asked_at}> asked {Deck.ago_words(@card.slide.asked_at)}</span>
            </span>
            <span :if={!@operator_source?} class="min-w-0 flex items-center gap-1.5 truncate">
              <Common.workspace_identity
                project={@card.slide.project_name}
                workspace={@card.slide.workspace_name}
                state={(@pending? && :needs_you) || :asleep}
                class="min-w-0"
              />
              <span class="truncate">
                ·
                <span class="font-semibold text-zinc-800 dark:text-zinc-100">{@card.slide.agent_name}</span>
                <span :if={@card.slide.asked_at}> asked {Deck.ago_words(@card.slide.asked_at)}</span>
              </span>
            </span>
            <span class="ml-auto flex-none inline-flex items-center gap-1 text-meta tabular-nums whitespace-nowrap">
              <a
                :if={@prev}
                href={"#slide-" <> @prev.dom_id}
                aria-label="Previous decision"
                class="focus-ring tap-target hidden md:inline-flex items-center justify-center w-7 h-7 rounded-sm hover:bg-zinc-100 dark:hover:bg-zinc-800"
              >
                ‹
              </a>
              <span
                :if={@total <= 12}
                class="inline-flex items-center gap-1"
                aria-label={"#{@index} of #{@total}"}
              >
                <span
                  :for={i <- 1..@total}
                  class={[
                    "block rounded-full",
                    (i == @index && "w-2 h-2 bg-orange-500") ||
                      "w-1.5 h-1.5 bg-zinc-300 dark:bg-zinc-600"
                  ]}
                ></span>
              </span>
              <span :if={@total > 12}>{@index} of {@total}</span>
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
                  · {@index} of {@total}
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

            <%!-- Parked sends, shown where they were sent from: the operator
            was busy, so this waits in its queue and goes out when it's
            free. Without this the message vanished until it drained. --%>
            <div
              :for={text <- @queued}
              class="mt-3 px-3 py-2 border-l-2 border-violet-400/60 bg-violet-500/5 text-lead text-zinc-700 dark:text-zinc-300"
            >
              <span class="block text-meta text-violet-600 dark:text-violet-400">
                Queued — the operator is busy; this sends when it's free
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
  def end_slide(assigns) do
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
          navigate={(@history? && "/operator/decisions") || "/operator/decisions/history"}
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

  # What the operator is doing while you wait — the honest word, not a
  # generic spinner. A queued send while it's idle means it's about to take it.
  defp waiting_line(status) when status in [:booting, :starting, :restarting],
    do: "Waking the operator…"

  defp waiting_line(:compacting), do: "The operator is tidying its context first…"
  defp waiting_line(:rate_limited), do: "The operator is rate-limited — it retries on its own"
  defp waiting_line(_), do: "Working on it…"

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
end
