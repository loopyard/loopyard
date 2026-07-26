defmodule LoopyardWeb.Components.FocusedView do
  @moduledoc """
  The FOCUSED VIEW shell — one piece of content, full screen, with its subject
  made unmistakable. The layout for anything presented as "slides": the question
  Reviewer, share permalinks, and future digests ("what happened in this repo" —
  key turns, quotes, summaries). One shell, so every focused surface reads the
  same:

    * top bar — a small label (what kind of view this is), optional position
      ("2 of 5"), optional nav controls, and the mode nav;
    * SUBJECT header — the project · workspace identity, PROMINENT (the
      canonical light + names at display size), with an optional context line;
    * a centered reading-measure column for the content itself.
  """
  use Phoenix.Component

  import LoopyardWeb.Components.Common, only: [mode_nav: 1]

  attr :label, :string, required: true, doc: "small uppercase kind label, e.g. \"Review\""
  attr :label_class, :string, default: "text-orange-700 dark:text-orange-400"
  attr :position, :string, default: nil, doc: "e.g. \"2 of 5\""
  attr :mode, :atom, default: nil
  slot :nav, doc: "optional controls (prev/next) in the top bar"
  slot :subject, doc: "the prominent subject header (use subject/1)"
  slot :inner_block, required: true

  def layout(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col bg-brand-paper dark:bg-brand-ink text-zinc-900 dark:text-zinc-100 safe-area-x safe-area-top">
      <div class="flex-none flex items-center gap-3 h-14 px-4 md:px-6 border-b border-zinc-200 dark:border-zinc-800">
        <span class={["chat-meta font-semibold uppercase tracking-wide", @label_class]}>
          {@label}
        </span>
        <span :if={@position} class="chat-meta tabular-nums text-zinc-500 dark:text-zinc-400">
          {@position}
        </span>
        <div class="flex-1"></div>
        {render_slot(@nav)}
        <.mode_nav active={@mode} class="ml-2" />
      </div>

      <div class="flex-1 overflow-y-auto">
        <div class="mx-auto w-full max-w-2xl px-4 md:px-6 py-6 md:py-10">
          {render_slot(@subject)}
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  The PROMINENT subject header: the canonical workspace identity at display
  size — a focused view must make its subject obvious at a glance (a tiny chip
  buried in a card is not enough when the content stands alone).
  """
  attr :project, :string, required: true
  attr :workspace, :string, default: nil
  attr :state, :atom, default: :asleep
  attr :context, :string, default: nil, doc: "one quiet line under the identity"

  def subject(assigns) do
    ~H"""
    <div class="mb-6">
      <div class="flex items-center gap-2.5 min-w-0">
        <span
          aria-hidden="true"
          class={["flex-none w-2.5 h-2.5 rounded-full", LoopyardWeb.Components.Common.state_light(@state)]}
        >
        </span>
        <h1 class="min-w-0 truncate text-xl md:text-2xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-50">
          {@project}<span
            :if={@workspace not in [nil, ""]}
            class="font-normal text-zinc-400 dark:text-zinc-500"
          > · {@workspace}</span>
        </h1>
      </div>
      <p :if={@context} class="chat-meta text-zinc-500 dark:text-zinc-400 mt-1.5 ml-[1.375rem]">
        {@context}
      </p>
    </div>
    """
  end
end
