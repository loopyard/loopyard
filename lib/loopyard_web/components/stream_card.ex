defmodule LoopyardWeb.Components.StreamCard do
  @moduledoc """
  The shared anatomy for every mini-app card in a chat stream.

  One card language, three pieces:

  * `band/1` — the full-bleed container. Same geometry as the human prompt
  band (edge-to-edge wash, the shared content gutter, a colored left rail),
  toned by meaning: `:needs_you` amber, `:you` violet, `:neutral` quiet.
  * `header/1` — the standard top row: the canonical `workspace_identity`
  chip TOP-LEFT (when the card knows its subject), the card's label
  TOP-RIGHT opposite it (uppercase, inheriting the card's size). Without a
  chip the label holds the left edge.
  * Actions/links belong at the BOTTOM of the card, built with
  `action_class/1` — the ONE geometry every decision button shares.

  Using these instead of hand-rolling containers/headers is what keeps every
  card aligned to the same gutter, size, and rhythm — see the question,
  approval, and secret cards in `Messages.Cards`.
  """
  use Phoenix.Component

  attr :tone, :atom, default: :needs_you, values: [:needs_you, :you, :neutral]

  attr :chrome, :atom,
    default: :always,
    values: [:always, :desktop],
    doc: """
    :always — the toned wash + rail at every size (the chat stream).
    :desktop — chrome from md: up only; on a PHONE the content takes the
    viewport bare (full-screen surfaces like the Reviewer, where a big toned
    box inside a small screen reads boxed-in).
    """

  attr :class, :string, default: nil
  slot :inner_block, required: true

  def band(assigns) do
    ~H"""
    <div class={[
      "-mx-4 md:-mx-6 wide:-mx-4 px-4 md:px-6 pt-4 md:pt-5 pb-4 md:pb-5 text-lead",
      band_tone(@tone, @chrome),
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # The left line MEANS "live — waiting on you / the active turn". Settled
  # receipts (:neutral) carry no line: the wash alone is the receipt.
  # Dark mode carries colour much further than light: the same wash and rail
  # that read as a calm tint on paper read as an alarm on ink. Both are damped
  # there, and only there.
  defp band_tone(:needs_you, :always),
    do:
      "border-l-2 bg-orange-50/70 dark:bg-orange-950/10 border-orange-400 dark:border-orange-500/40"

  defp band_tone(:you, :always),
    do: "border-l-2 bg-violet-100 dark:bg-[#2b2348] border-violet-500 dark:border-violet-400"

  # The rail is still THERE on a settled card — a card that dropped its 2px
  # border moved its whole content 2px left, a shift you see without being
  # able to name it — but it is painted in the card's own wash rather than
  # left transparent, which showed as a pale line down the left edge on ink.
  defp band_tone(:neutral, :always),
    do:
      "border-l-2 border-zinc-500/[0.06] dark:border-white/[0.045] bg-zinc-500/[0.06] dark:bg-white/[0.045]"

  defp band_tone(:needs_you, :desktop),
    do:
      "md:border-l-2 md:bg-orange-50/70 md:dark:bg-orange-950/10 md:border-orange-400 md:dark:border-orange-500/40"

  defp band_tone(:you, :desktop),
    do:
      "md:border-l-2 md:bg-violet-100 md:dark:bg-[#2b2348] md:border-violet-500 md:dark:border-violet-400"

  defp band_tone(:neutral, :desktop),
    do:
      "md:border-l-2 md:border-zinc-500/[0.06] md:dark:border-white/[0.045] md:bg-zinc-500/[0.06] md:dark:bg-white/[0.045]"

  attr :project, :string, default: nil
  attr :workspace, :string, default: nil
  attr :state, :atom, default: :needs_you
  attr :label_class, :string, default: "text-orange-700 dark:text-orange-400"
  slot :label, required: true

  def header(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3 mb-2 min-w-0">
      <LoopyardWeb.Components.Common.workspace_identity
        :if={@project not in [nil, ""]}
        project={@project}
        workspace={@workspace}
        state={@state}
        class="min-w-0"
      />
      <span class={[
        "flex items-center gap-1.5 font-semibold uppercase tracking-wide flex-none",
        @label_class
      ]}>
        {render_slot(@label)}
      </span>
    </div>
    """
  end

  @doc """
  The class list for a decision button — Answer, Skip, Chat, Approve, Deny.

  ONE geometry, because every one of these is the same act: a thing you tap to
  resolve a card. They were hand-rolled per card and drifted, so on a phone the
  primary stood 52px tall while the secondaries sat at 40px in a stack of
  matching outlines — three targets, three sizes, one row.

  Same height everywhere; `variant` carries the only difference that means
  anything, which is WEIGHT:

    * `:primary` — the move the card exists for. Filled, `tone` picks the fill.
    * `:ghost` — the alternatives. No border, no fill; they read as available
      without competing. (Outlines at matching size read as equal weight, which
      is how Deny came to look exactly as important as Approve.)

  Uniform size means SIZE no longer separates a commit from a discard, so the
  footer that uses these has to buy that back with DISTANCE — see the question
  card's footer.
  """
  @spec action_class(keyword()) :: list()
  def action_class(opts \\ []) do
    variant = Keyword.get(opts, :variant, :ghost)
    tone = Keyword.get(opts, :tone, :flame)

    [
      # min-h on the PHONE is the real floor (a 52px row is comfortable for a
      # thumb); desktop steps down to 44 because a pointer needs less.
      "focus-ring inline-flex items-center justify-center gap-1.5 rounded-sm",
      "px-5 min-h-[3.25rem] sm:min-h-11 text-lead transition-colors",
      case variant do
        :primary ->
          ["font-semibold text-white shadow-sm ", primary_fill(tone)]

        :ghost ->
          "font-medium text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800"
      end
    ]
  end

  defp primary_fill(:flame), do: "bg-orange-600 hover:bg-orange-700 shadow-orange-600/30"
  defp primary_fill(:confirm), do: "bg-emerald-600 hover:bg-emerald-700 shadow-emerald-900/20"
  defp primary_fill(:danger), do: "bg-red-600 hover:bg-red-700 shadow-red-900/20"
end
