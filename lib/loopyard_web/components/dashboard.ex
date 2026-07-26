defmodule LoopyardWeb.Components.Dashboard do
  @moduledoc """
  The home dashboard's building block: a read-only **status card**. One card per
  area of the system (Workspaces / Remote / System / Operated). Each shows a
  status dot + word and a short live summary, and navigates into that area. The
  cards are the homepage — they replace the old mobile overflow menu.

  Pure presentation: `DashboardLive` owns the live data (PubSub + a refresh tick)
  and passes each card its current snapshot.
  """
  use Phoenix.Component

  @doc """
  A single status card.

    * `navigate` — where tapping the card goes.
    * `title` — the area name.
    * `tone` — `:ok | :warn | :down | :neutral`, drives the dot + status color.
    * `status` — short status word shown top-right (e.g. "healthy", "exposed").
    * `:inner_block` — the live summary line(s).
  """
  attr :navigate, :string, required: true
  attr :title, :string, required: true
  attr :tone, :atom, default: :neutral, values: [:ok, :warn, :down, :neutral]
  attr :status, :string, default: nil
  slot :inner_block, required: true

  def dashboard_card(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="group flex flex-col rounded-2xl border border-zinc-200 dark:border-zinc-800 bg-brand-paper dark:bg-brand-ink/40 p-5 hover:border-violet-300 dark:hover:border-violet-500/40 hover:bg-zinc-50/60 dark:hover:bg-zinc-800/30 transition-colors"
    >
      <div class="flex items-center gap-2.5">
        <span class={["w-2.5 h-2.5 rounded-full flex-none", dot_tone(@tone)]}></span>
        <h2 class="text-base font-semibold text-zinc-900 dark:text-zinc-50">{@title}</h2>
        <span :if={@status} class={["ml-auto text-xs font-semibold uppercase tracking-wide", text_tone(@tone)]}>
          {@status}
        </span>
      </div>
      <div class="mt-3 text-sm text-zinc-500 dark:text-zinc-400 leading-relaxed">
        {render_slot(@inner_block)}
      </div>
    </.link>
    """
  end

  @doc "Responsive card grid — one column on phones, two from `sm` up."
  slot :inner_block, required: true

  def dashboard_grid(assigns) do
    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 sm:gap-4">
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp dot_tone(:ok), do: "bg-emerald-500"
  defp dot_tone(:warn), do: "bg-amber-500"
  defp dot_tone(:down), do: "bg-red-500"
  defp dot_tone(_), do: "bg-sky-500"

  defp text_tone(:ok), do: "text-emerald-600 dark:text-emerald-400"
  defp text_tone(:warn), do: "text-amber-600 dark:text-amber-400"
  defp text_tone(:down), do: "text-red-600 dark:text-red-400"
  defp text_tone(_), do: "text-sky-600 dark:text-sky-400"
end
