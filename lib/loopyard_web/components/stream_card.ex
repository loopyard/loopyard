defmodule LoopyardWeb.Components.StreamCard do
  @moduledoc """
  The shared anatomy for every mini-app card in a chat stream.

  One card language, three pieces:

  * `band/1` — the full-bleed container. Same geometry as the human prompt
  band (edge-to-edge wash, the shared content gutter, a colored left rail),
  toned by meaning: `:needs_you` amber, `:you` violet, `:neutral` quiet.
  * `header/1` — the standard top row: the canonical `workspace_identity`
  chip TOP-LEFT (when the card knows its subject), the card's label
  TOP-RIGHT opposite it (icon + uppercase `chat-meta` text). Without a
  chip the label holds the left edge.
  * Actions/links belong at the BOTTOM of the card (convention, not markup).

  Using these instead of hand-rolling containers/headers is what keeps every
  card aligned to the same gutter, size, and rhythm — see the question,
  approval, and secret cards in `Messages.Cards`.
  """
  use Phoenix.Component

  attr :tone, :atom, default: :needs_you, values: [:needs_you, :you, :neutral]
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def band(assigns) do
    ~H"""
    <div class={[
      "-mx-4 md:-mx-6 2xl:-mx-4 px-4 md:px-6 lg:px-8 pt-4 md:pt-5 pb-4 md:pb-5",
      band_tone(@tone),
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # The left line MEANS "live — waiting on you / the active turn". Settled
  # receipts (:neutral) carry no line: the wash alone is the receipt.
  defp band_tone(:needs_you),
    do:
      "border-l-2 bg-orange-50/70 dark:bg-orange-950/15 border-orange-400 dark:border-orange-500/60"

  defp band_tone(:you),
    do: "border-l-2 bg-violet-100 dark:bg-[#2b2348] border-violet-500 dark:border-violet-400"

  defp band_tone(:neutral),
    do: "bg-zinc-500/[0.06] dark:bg-white/[0.045]"

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
        size={:sm}
        class="min-w-0"
      />
      <span class={[
        "chat-meta flex items-center gap-1.5 font-semibold uppercase tracking-wide flex-none",
        @label_class
      ]}>
        {render_slot(@label)}
      </span>
    </div>
    """
  end
end
