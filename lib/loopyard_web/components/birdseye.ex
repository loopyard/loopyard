defmodule LoopyardWeb.Components.Birdseye do
  @moduledoc """
  The shared visual language for the two birdseye surfaces (#55): the compact
  left **sidebar** and the expanded **home page**. They're the same system at
  two zoom levels — so the atoms (status dot, openable port chip, the
  "what's this agent doing" line, the status→color mapping) live here and are
  rendered by both. Move between the rail and the home page and everything reads
  the same, so you keep your bearings.

  Every helper takes the raw agent maps the tree produces (`:status`,
  `:active_tool`, `:id`, `:quarantined`, …) and runs them through the ONE
  canonical normalizer (`LoopyardWeb.Components.Sidebar.agent_display_status/1`),
  so a given agent looks identical in the rail, on the home page, and on its
  own page.
  """
  use Phoenix.Component

  alias LoopyardWeb.Components.Sidebar

  # Meaningful-only colors, driven by the agent's raw `:status` — which the
  # LiveView keeps fresh by patching from StatusChanged events. This is
  # DELIBERATELY not `agent_display_status/1`: that does a render-time Registry
  # liveness lookup which is nondeterministic during an agent's session
  # restarts, so the dot would blink out mid-work. A pure status→color mapping
  # renders identically every time → visually stable. A dot appears ONLY when
  # there's something to know (working / attention / ready); everything else →
  # nil (an aligned blank, not a confusing gray circle).
  @working [:thinking, :compacting, :booting, :backoff, :rate_limited]
  @attention [:crashed, :auth_expired]

  defp status_color(s) when s in @working, do: "bg-violet-500 animate-pulse"
  defp status_color(s) when s in @attention, do: "bg-red-500"
  defp status_color(:idle), do: "bg-green-500"
  defp status_color(_), do: nil

  @doc "Dot color class (or nil) for a single agent's live status."
  def agent_dot(agent), do: status_color(Map.get(agent, :status))

  @doc """
  Dot color (or nil) for a group of agents — loudest state wins:
  needs-attention > working > ready. Anything else / no agents → nil (no dot).
  Agrees with the individual agent dots it summarizes.
  """
  def aggregate_dot(agents) do
    statuses = Enum.map(agents, &Map.get(&1, :status))

    cond do
      Enum.any?(statuses, &(&1 in @attention)) -> "bg-red-500"
      Enum.any?(statuses, &(&1 in @working)) -> "bg-violet-500 animate-pulse"
      Enum.any?(statuses, &(&1 == :idle)) -> "bg-green-500"
      true -> nil
    end
  end

  @doc """
  Plain-language "what's up with this agent" line — the same wording in the rail
  tooltip and the home page row.
  """
  def agent_activity(agent) do
    case Sidebar.agent_display_status(agent) do
      :thinking ->
        case Map.get(agent, :active_tool) do
          tool when is_binary(tool) and tool != "" -> tool
          _ -> "working…"
        end

      :ready ->
        "idle"

      :crashed ->
        "needs attention"

      :quarantined ->
        "quarantined"

      _ ->
        "asleep"
    end
  end

  @doc """
  A live status dot. `class` nil → an aligned blank (holds the slot so names
  stay lined up, but shows no confusing gray circle). `size` is `:sm` (rail) or
  `:md` (home).
  """
  attr :class, :string, default: nil
  attr :size, :atom, default: :sm, values: [:sm, :md]

  def dot(assigns) do
    ~H"""
    <span class={[
      "flex-none rounded-full",
      @size == :sm && "h-2 w-2",
      @size == :md && "h-2.5 w-2.5",
      @class
    ]} />
    """
  end

  @doc """
  A light, clickable port chip — `:4003` — that opens the running app in a new
  tab. The cluster's "it's up, go look" affordance. Right-aligned in the row's
  second column; same chip in the rail and on the home page.
  """
  attr :port, :integer, required: true
  attr :url, :string, required: true

  def port_chip(assigns) do
    ~H"""
    <a
      href={@url}
      target="_blank"
      rel="noopener"
      class="group/port inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[11px] font-mono text-emerald-600/90 dark:text-emerald-400/90 hover:bg-emerald-50 dark:hover:bg-emerald-500/10 hover:text-emerald-700 dark:hover:text-emerald-300 transition-colors"
      title={"Open the running app (#{@url})"}
      onclick="event.stopPropagation()"
    >
      :{@port}
      <svg
        viewBox="0 0 20 20"
        fill="currentColor"
        class="w-2.5 h-2.5 opacity-0 group-hover/port:opacity-100 transition-opacity"
      ><path d="M11 3a1 1 0 1 0 0 2h2.586l-6.293 6.293a1 1 0 1 0 1.414 1.414L15 6.414V9a1 1 0 1 0 2 0V4a1 1 0 0 0-1-1h-5Z" /><path d="M5 5a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2v-3a1 1 0 1 0-2 0v3H5V7h3a1 1 0 0 0 0-2H5Z" /></svg>
    </a>
    """
  end
end
