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

  @doc "Dot color class for a single agent's live display status."
  def agent_dot(agent), do: Sidebar.status_dot(Sidebar.agent_display_status(agent))

  @doc """
  Dot color for a group of agents — loudest DISPLAY state wins (red > working >
  ready > asleep). Used for a project or workspace rollup; agrees with the
  individual agent dots it summarizes.
  """
  def aggregate_dot([]), do: Sidebar.status_dot(:sleeping)

  def aggregate_dot(agents) do
    displays = Enum.map(agents, &Sidebar.agent_display_status/1)

    cond do
      Enum.any?(displays, &(&1 in [:crashed, :quarantined])) -> Sidebar.status_dot(:crashed)
      Enum.any?(displays, &(&1 == :thinking)) -> Sidebar.status_dot(:thinking)
      Enum.any?(displays, &(&1 == :ready)) -> Sidebar.status_dot(:ready)
      true -> Sidebar.status_dot(:sleeping)
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

  @doc "A live status dot. `size` is `:sm` (rail) or `:md` (home)."
  attr :class, :string, required: true
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
  An openable port: `:4003 ↗`. Opens the running app in a new tab. Identical in
  the rail and on the home page so a port is always the same recognizable chip.
  """
  attr :port, :integer, required: true
  attr :url, :string, required: true

  def port_chip(assigns) do
    ~H"""
    <a
      href={@url}
      target="_blank"
      rel="noopener"
      class="inline-flex items-center gap-1 rounded-md bg-emerald-50 dark:bg-emerald-500/10 px-1.5 py-0.5 text-[11px] font-mono font-medium text-emerald-700 dark:text-emerald-400 hover:bg-emerald-100 dark:hover:bg-emerald-500/20 transition-colors"
      title={"Open #{@url}"}
      onclick="event.stopPropagation()"
    >
      :{@port}
      <svg viewBox="0 0 20 20" fill="currentColor" class="w-3 h-3"><path d="M11 3a1 1 0 1 0 0 2h2.586l-6.293 6.293a1 1 0 1 0 1.414 1.414L15 6.414V9a1 1 0 1 0 2 0V4a1 1 0 0 0-1-1h-5Z" /><path d="M5 5a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2v-3a1 1 0 1 0-2 0v3H5V7h3a1 1 0 0 0 0-2H5Z" /></svg>
    </a>
    """
  end
end
