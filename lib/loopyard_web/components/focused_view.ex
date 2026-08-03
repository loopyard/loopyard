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

  attr :crumbs, :list,
    default: [],
    doc:
      "breadcrumb trail for the top-left anchor, e.g. [{\"loopyard\", \"/\"}, {\"Operator\", \"/operator\"}]"

  slot :nav, doc: "optional controls (prev/next) in the top bar"
  slot :subject, doc: "the prominent subject header (use subject/1)"
  slot :inner_block, required: true

  def layout(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col bg-brand-paper dark:bg-brand-ink text-zinc-900 dark:text-zinc-100 safe-area-x safe-area-top">
      <%!-- Three zones: an anchor UP on the left, where every other page in the
           app puts it; the label + position CENTERED (it describes the deck,
           not the app); nav + modes right. Focused views used to lead with
           "REVIEW 1 of 3" and no breadcrumb at all, which left the most
           attention-hungry screens in the product as the only ones with no
           visible way home. --%>
      <%!-- Centred from sm: up only. At 390px there isn't room to centre a
           title AND clear the nav + mode icons — "Operator REVIEW 1 of 3" sat
           on top of them. Same rule as AppHeader. --%>
      <div class="app-bar flex-none grid grid-cols-[auto_1fr_auto] sm:grid-cols-[1fr_auto_1fr] items-center gap-3 h-14 px-4 md:px-6 border-b border-zinc-200 dark:border-zinc-800">
        <%!-- Three zones (see Breadcrumbs.trail/1): brand + ancestors left, the
             CURRENT thing centred, nav right. Through with_root/1 so the trail
             always leads with the brand crumb — brand_root?/2 matches the exact
             label "Loopyard" to swap in the trefoil, and a hand-written crumb
             that misses it renders as bare text with no mark. --%>
        <% crumbs = LoopyardWeb.Components.AppHeader.with_root(@crumbs) %>
        <div class="min-w-0">
          <LoopyardWeb.Components.Breadcrumbs.trail
            :if={@crumbs != []}
            crumbs={crumbs}
            include_current
          />
        </div>

        <%!-- nowrap + truncate: at 390px the nav is five items wide, so the
             centre column gets squeezed and "1 of 3" wrapped AROUND the
             history icon — a number broken across two lines reads as
             corruption. It now shortens rather than wraps. --%>
        <div class="flex items-center gap-2 justify-start sm:justify-center min-w-0 overflow-hidden">
          <span class={[
            "text-meta font-semibold uppercase tracking-wide whitespace-nowrap truncate",
            @label_class
          ]}>
            {@label}
          </span>
          <span
            :if={@position}
            class="text-meta tabular-nums whitespace-nowrap flex-none text-zinc-500 dark:text-zinc-400"
          >
            {@position}
          </span>
        </div>

        <div class="flex items-center justify-end min-w-0">
          {render_slot(@nav)}
          <.mode_nav active={@mode} class="ml-2" />
        </div>
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
          class={[
            "flex-none w-2.5 h-2.5 rounded-full",
            LoopyardWeb.Components.Common.state_light(@state)
          ]}
        ></span>
        <h1 class="min-w-0 truncate text-title font-semibold tracking-tight text-zinc-900 dark:text-zinc-50">
          {@project}<span
            :if={@workspace not in [nil, ""]}
            class="font-normal text-zinc-400 dark:text-zinc-500"
          > · {@workspace}</span>
        </h1>
      </div>
      <p :if={@context} class="text-meta text-zinc-500 dark:text-zinc-400 mt-1.5 ml-[1.375rem]">
        {@context}
      </p>
    </div>
    """
  end
end
