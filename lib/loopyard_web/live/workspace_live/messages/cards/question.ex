defmodule LoopyardWeb.Live.WorkspaceLive.Messages.Cards.Question do
  @moduledoc """
  The `ask_user` **question** card and its per-question atom
  (`question_block/1`). Split out of
  `LoopyardWeb.Live.WorkspaceLive.Messages.Cards` — see that module for the
  card family overview. Template-only; no socket/PubSub.
  """
  use Phoenix.Component

  @doc """
  The agent asked the user a question (via the `ask_user` tool or the harness's
  native AskUserQuestion over ACP form elicitation). An interactive decision
  card — options as buttons.

  Mirrors the native tool's semantics: each question resolves INDEPENDENTLY
  (answer, skip, or type your own), the whole ask returns to the agent only
  when every question is settled, and multi-select questions toggle then
  confirm. Everything is broadcast (multiplayer) — a question someone else
  already answered renders locked with their choice.
  """
  def question_card(assigns) do
    ~H"""
    <div class="py-2">
      <%!-- Quiet decision panel: a light amber WASH signals "needs you" (amber,
    NOT violet — violet is the "You" message colour). Options sit on white
    rows so they stay distinct on the tint. Reads top-down: label ›
    question (hero) › the options, each anchored by a radio/check dot. --%>
      <LoopyardWeb.Components.StreamCard.band tone={
        (@msg.status == :pending && :needs_you) || :neutral
      }>
        <%!-- Card anatomy (every stream card): identity chip TOP-LEFT (which
    project·workspace this is about — the canonical design-language
    badge), the card's label TOP-RIGHT opposite it; actions live at
    the BOTTOM. Without a source the label holds the left edge. --%>
        <div class="flex items-center justify-between gap-3 mb-2 min-w-0">
          <LoopyardWeb.Components.Common.workspace_identity
            :if={@msg[:source] not in [nil, ""]}
            project={source_project(@msg.source)}
            workspace={source_workspace(@msg.source)}
            state={if @msg.status == :pending, do: :needs_you, else: :done}
            size={:sm}
            class="min-w-0"
          />
          <span class={[
            "chat-meta flex items-center gap-1.5 font-semibold uppercase tracking-wide flex-none",
            (@msg.status == :pending && "text-orange-700 dark:text-orange-400") ||
              "text-zinc-500 dark:text-zinc-400"
          ]}>
            {case @msg.status do
              :pending -> "Decision"
              :timeout -> "No answer"
              _ -> "Answered"
            end}
            <span
              :if={length(@msg.questions) > 1}
              class="normal-case tracking-normal tabular-nums text-zinc-500 dark:text-zinc-400"
            >
              {Enum.count(@msg.questions, &locked?(@msg, &1))}/{length(@msg.questions)}
            </span>
          </span>
        </div>

        <.question_block :for={q <- @msg.questions} msg={@msg} q={q} />

        <div
          :if={@msg.status == :pending}
          class="chat-meta mt-4 pt-3 border-t border-zinc-200 dark:border-zinc-800 text-zinc-500 dark:text-zinc-400"
        >
          …or just reply in the chat — your message is sent to the agent as the answer.
        </div>

        <div :if={@msg.status == :timeout} class="chat-meta text-zinc-500 dark:text-zinc-400">
          No answer — the agent moved on.
        </div>
      </LoopyardWeb.Components.StreamCard.band>
    </div>
    """
  end

  @doc """
  ONE question's full interactive unit — header eyebrow, prompt, options,
  Other…/Skip, and the settled receipt. The question card loops these; the
  Reviewer renders exactly one per slide. This is the question design
  language's atom: same everywhere a question appears.
  """
  attr :msg, :map, required: true
  attr :q, :map, required: true

  attr :chat_path, :string,
    default: nil,
    doc: """
    When set, the footer gains a "Chat" action beside Skip/Answer. The Reviewer
    passes the slide's chat path; the in-transcript card doesn't, because you're
    already in the chat. Owning it here keeps the three actions in ONE row
    instead of two buttons plus a sentence with a link floating below the card.
    """

  def question_block(assigns) do
    ~H"""
    <div class="mb-8 last:mb-0">
      <div
        :if={@q.header != ""}
        class="chat-meta font-semibold uppercase tracking-wider text-zinc-400 dark:text-zinc-500 mb-1"
      >
        {@q.header}
      </div>
      <div class="chat-body font-semibold leading-snug text-zinc-900 dark:text-zinc-50 mb-3">
        {@q.prompt}
      </div>

      <%!-- PENDING: interactive options. Each is a scannable row anchored by
    a radio/check dot. Single-select: one click settles. Multi-select:
    clicks TOGGLE (draft broadcast to all viewers); the dot fills and
    the button below confirms. --%>
      <%!-- PENDING is ONE form: option taps DRAFT (type="button"), the Other
    row is just another draftable row (its text input belongs to this
    form), and the question's single commit action lives in the footer —
    Answer (submit: typed text wins, else the drafted option) next to
    Skip. The commit button never sits inside an option row; that read
    as "Answer the Other text" and buried the hierarchy. --%>
      <form
        :if={@msg.status == :pending && !locked?(@msg, @q)}
        id={"qopts-#{@msg[:id] || @msg.question_id}-#{@q.id}"}
        phx-hook="QuestionOptions"
        phx-change="draft_question_option"
        phx-submit="answer_question_text"
        class="group/qform flex flex-col gap-1"
      >
        <input type="hidden" name="question_id" value={@msg.question_id} />
        <input type="hidden" name="q" value={@q.id} />
        <%!-- A REAL input, so the BROWSER owns selection and it lands on the
    frame you tapped. These were <button phx-click>s whose every visual
    state came from a server assign: the tap round-tripped, and under any
    load the late re-render arrived after you'd already moved on — which
    is exactly the "checks, then unchecks" flicker. Nothing here waits on
    the server now; the peer-checked rules do the whole selected look,
    and the form carries the choice on submit. `phx-change` still tells
    the server (multiplayer + durability), but no pixel depends on it. --%>
        <label
          :for={o <- @q.options}
          class="q-option focus-ring group/opt relative flex w-full cursor-pointer items-start gap-3 rounded-sm px-3 py-2.5 md:py-2 text-left"
        >
          <input
            type={(@q[:multi] && "checkbox") || "radio"}
            name={(@q[:multi] && "options[]") || "option"}
            value={o.label}
            checked={drafted?(@msg, @q, o.label)}
            class="peer sr-only"
          />
          <span
            aria-hidden="true"
            class="pointer-events-none absolute inset-0 rounded-sm transition-colors group-hover/opt:bg-orange-500/[0.07] dark:group-hover/opt:bg-orange-500/10 peer-checked:bg-orange-500/15 dark:peer-checked:bg-orange-500/20 peer-checked:ring-1 peer-checked:ring-orange-500/70"
          ></span>
          <span
            aria-hidden="true"
            class="q-dot relative mt-px flex h-[18px] w-[18px] flex-none items-center justify-center rounded-full border-2 text-transparent transition-colors border-zinc-300 group-hover/opt:border-orange-400 dark:border-zinc-600 dark:group-hover/opt:border-orange-500 peer-checked:border-orange-500 peer-checked:bg-orange-500 peer-checked:text-white"
          >
            <.check />
          </span>
          <span class="relative min-w-0 flex-1">
            <span class="chat-sub block font-medium text-zinc-900 dark:text-zinc-100">
              {o.label}
            </span>
            <span
              :if={o.description not in [nil, ""]}
              class="chat-sub mt-0.5 block text-zinc-600 dark:text-zinc-400"
            >
              {o.description}
            </span>
          </span>
        </label>

        <%!-- "Other" is another draftable row: same grammar as the options —
    click in, type your own answer. Enter or the footer's Answer
    submits it (typed text wins over a drafted option). --%>
        <div class="group/opt flex w-full items-center gap-3 rounded-sm px-3 py-1 transition-all focus-within:bg-orange-500/15 dark:focus-within:bg-orange-500/20 focus-within:ring-1 focus-within:ring-orange-500/70">
          <span
            aria-hidden="true"
            class="flex h-[18px] w-[18px] flex-none items-center justify-center rounded-full border-2 border-zinc-300 dark:border-zinc-600 group-focus-within/opt:border-orange-500 group-focus-within/opt:bg-orange-500 transition-colors"
          ></span>
          <input
            type="text"
            name="text"
            autocomplete="off"
            placeholder="Other…"
            phx-focus="draft_question_other"
            data-qother
            phx-value-question_id={@msg.question_id}
            phx-value-q={@q.id}
            class="chat-sub min-w-0 flex-1 border-0 bg-transparent px-0 py-2 font-medium text-zinc-900 dark:text-zinc-100 placeholder-zinc-500 dark:placeholder-zinc-400 focus:outline-none focus:ring-0"
          />
        </div>

        <%!-- The question's footer: Skip (quiet, left) — the ONE commit action
    (right). Single-select: Answer submits the form. Multi: Done
    confirms the toggled draft. --%>
        <%!-- MOBILE: Answer on top, full width — the primary move reads first
    and is the biggest target. The two ghosts stack in a column beneath
    it, also full width, so the whole footer is one predictable column
    rather than three things squeezed onto a 390px line.
    DESKTOP (sm:+): Answer sits LEFT at half width, directly below the
    options it commits — the eye finishes the last option and lands on
    the button, instead of tracking to the far corner. The two ghosts
    go right. All targets clear 44px. --%>
        <div class={[
          "mt-3 flex flex-col sm:flex-row sm:items-center gap-2",
          (@q[:multi] && "sm:justify-end") || "sm:justify-between"
        ]}>
          <%!-- Set apart from the primary on mobile (mt-3) and deliberately
      smaller (min-h-10 vs 52px, chat-meta vs text-base). Skip also sits
      LAST — furthest from Answer — because it was directly beneath the
      primary at identical weight, which made discarding a question a
      plausible mis-tap. Size + distance beats a confirm-tap: requiring a
      double-tap punishes every correct use to guard a rare wrong one,
      and nothing on screen would teach it. --%>
          <div
            :if={!@q[:multi]}
            class="flex flex-col sm:flex-row sm:items-center gap-2 mt-3 sm:mt-0 order-last sm:ml-auto"
          >
            <button
              :if={!@q[:multi]}
              type="button"
              phx-click="skip_question"
              phx-value-question_id={@msg.question_id}
              phx-value-q={@q.id}
              class="focus-ring chat-meta w-full sm:w-auto order-last sm:order-first inline-flex items-center justify-center rounded-sm px-4 min-h-10 text-zinc-400 dark:text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
            >
              Skip
            </button>
            <.link
              :if={!@q[:multi] && @chat_path}
              navigate={@chat_path}
              class="focus-ring chat-meta w-full sm:w-auto inline-flex items-center justify-center rounded-sm border border-zinc-300 dark:border-zinc-600 px-4 min-h-10 text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800 transition-colors"
            >
              Chat
            </.link>
          </div>

          <button
            :if={!@q[:multi]}
            type="submit"
            class={
              [
                "focus-ring w-full sm:w-1/2 order-first inline-flex items-center justify-center rounded-sm text-base font-semibold px-6 min-h-[3.25rem] sm:min-h-12 transition-all",
                if(draft_count(@msg, @q) > 0,
                  do: "bg-orange-600 hover:bg-orange-700 text-white shadow-md shadow-orange-600/30",
                  # Lights up the INSTANT you pick, with no server round-trip.
                  # draft_count is a server assign and a radio click is purely
                  # client-side, so the commit button sat dead grey after
                  # selecting an option — it only woke on submit, which is
                  # backwards. `group-has-[:checked]` covers the options and the
                  # existing data-qother rule covers free text.
                  else:
                    "bg-zinc-200 text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400 " <>
                      "group-has-[:checked]/qform:bg-orange-600 " <>
                      "group-has-[:checked]/qform:text-white " <>
                      "group-has-[:checked]/qform:shadow-md " <>
                      "group-has-[:checked]/qform:shadow-orange-600/30 " <>
                      "group-has-[[data-qother]:not(:placeholder-shown)]/qform:bg-orange-600 " <>
                      "group-has-[[data-qother]:not(:placeholder-shown)]/qform:text-white " <>
                      "group-has-[[data-qother]:not(:placeholder-shown)]/qform:shadow-md " <>
                      "group-has-[[data-qother]:not(:placeholder-shown)]/qform:shadow-orange-600/30"
                )
              ]
            }
          >
            Answer
          </button>
          <button
            :if={@q[:multi]}
            type="button"
            phx-click="confirm_question"
            phx-value-question_id={@msg.question_id}
            phx-value-q={@q.id}
            class="focus-ring chat-sub flex-none inline-flex items-center rounded-sm bg-orange-700 hover:bg-orange-800 text-white font-medium px-4 py-2 transition-colors"
          >
            {if draft_count(@msg, @q) > 0,
              do: "Done (#{draft_count(@msg, @q)} selected)",
              else: "None of these"}
          </button>
        </div>
      </form>

      <%!-- SETTLED: same rows (no layout jump), chosen lit emerald with a
    filled check, the rest quietly dimmed but legible. Durable
    receipt — survives refresh/restart via persisted :selections. --%>
      <div :if={locked?(@msg, @q)} class="flex flex-col gap-0.5">
        <div
          :for={o <- @q.options}
          class={[
            "flex items-start gap-3 rounded-sm px-3 py-2 md:py-1.5",
            if(chosen?(@msg, @q, o.label),
              do: "bg-emerald-500/12 dark:bg-emerald-500/12",
              else: "opacity-60"
            )
          ]}
        >
          <span
            aria-hidden="true"
            class={[
              "mt-px flex h-[18px] w-[18px] flex-none items-center justify-center rounded-full border-2",
              if(chosen?(@msg, @q, o.label),
                do: "border-emerald-500 bg-emerald-500 text-white",
                else: "border-zinc-300 dark:border-zinc-600"
              )
            ]}
          >
            <.check :if={chosen?(@msg, @q, o.label)} />
          </span>
          <span class="min-w-0 flex-1">
            <span class={[
              "chat-sub block font-medium",
              if(chosen?(@msg, @q, o.label),
                do: "text-emerald-800 dark:text-emerald-200",
                else: "text-zinc-600 dark:text-zinc-400"
              )
            ]}>
              {o.label}
            </span>
            <span
              :if={o.description not in [nil, ""]}
              class={[
                "chat-sub mt-0.5 block",
                if(chosen?(@msg, @q, o.label),
                  do: "text-emerald-700/80 dark:text-emerald-300/70",
                  else: "text-zinc-500 dark:text-zinc-500"
                )
              ]}
            >
              {o.description}
            </span>
          </span>
        </div>

        <%!-- No option row matched: a free-text answer (show it) or a skip. --%>
        <div :if={!any_option_chosen?(@msg, @q)} class="chat-sub flex flex-wrap items-center gap-2">
          <span
            :if={answer_for(@msg, @q)}
            class="inline-flex items-center gap-1.5 rounded-sm bg-emerald-500/15 px-3 py-1.5 font-medium text-emerald-700 dark:text-emerald-300"
          >
            {answer_for(@msg, @q)}
          </span>
          <span
            :if={!answer_for(@msg, @q)}
            class="inline-flex items-center gap-1.5 rounded-sm bg-zinc-500/10 px-3 py-1.5 font-medium text-zinc-500 dark:text-zinc-400"
          >
            Skipped
          </span>
        </div>
      </div>
    </div>
    """
  end

  # Small check glyph for the filled radio/answered dots. A crisp stroked check
  # reads better than a text "✓" at this size and inherits currentColor.
  defp check(assigns) do
    ~H"""
    <svg viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2.25" class="h-3 w-3">
      <path d="M2.5 6.5 5 9l4.5-5.5" stroke-linecap="round" stroke-linejoin="round" />
    </svg>
    """
  end

  # The memo source is a "project · workspace" string (set by ask_user's source
  # param) — split it back into the two identity parts for the chip. A source
  # without the separator renders as just the project (no fake workspace).
  defp source_project(source), do: source |> String.split(" · ", parts: 2) |> hd()

  defp source_workspace(source) do
    case String.split(source, " · ", parts: 2) do
      [_project, workspace] -> workspace
      _ -> nil
    end
  end

  # A question is settled once it's in the message's `done` list (per-question
  # progressive answering) or the whole ask has resolved.
  defp locked?(msg, q),
    do: msg.status != :pending or q.id in (msg[:done] || [])

  # Multi-select draft state (selections accumulate before Done confirms).
  defp drafted?(%{selections: sel}, q, label) when is_map(sel),
    do: label in Map.get(sel, q.id, [])

  defp drafted?(_msg, _q, _label), do: false

  defp draft_count(%{selections: sel}, q) when is_map(sel),
    do: length(Map.get(sel, q.id, []))

  defp draft_count(_msg, _q), do: 0

  # The human's chosen answer for a question, once settled — nil when the
  # question was skipped (empty selection), so the card shows the explicit
  # "Skipped" receipt instead of a phantom "answered".
  defp answer_for(%{selections: sel}, q) when is_map(sel) do
    case Map.get(sel, q.id, []) do
      [] -> nil
      chosen -> Enum.join(chosen, ", ")
    end
  end

  defp answer_for(_msg, _q), do: nil

  # Was this option's label among the persisted selections for question q?
  defp chosen?(%{selections: sel}, q, label) when is_map(sel),
    do: label in Map.get(sel, q.id, [])

  defp chosen?(_msg, _q, _label), do: false

  # Did ANY listed option match the selections? False for free-text answers
  # (typed in chat), which need the text chip fallback instead.
  defp any_option_chosen?(msg, q),
    do: Enum.any?(q.options, &chosen?(msg, q, &1.label))
end
