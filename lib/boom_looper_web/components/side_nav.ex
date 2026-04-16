defmodule BoomLooperWeb.Components.SideNav do
  @moduledoc """
  Building blocks for sidebar panels. The workspace sidebar (agents,
  services, volumes) and the agent-context sidebar (info, docker,
  claude, tools) both render a vertical list of labeled sections —
  identical problem, identical shape. Every spacing/contrast/typography
  decision lives here so a fix in one place fixes both.

  Composition:

      <.section label="Agents">
        <.row navigate={path}>
          <.dot class="bg-emerald-500" />
          <span class="truncate">True Bloom</span>
        </.row>
        <.empty :if={empty?} text="No agents" />
      </.section>

      <.section label="Info">
        <.info_row label="Status" value={status} />
      </.section>
  """

  use Phoenix.Component

  # --- Section: label + content ---
  #
  # Rhythm for ALL sidebar sections is owned here. No section sets its
  # own padding, no consumer remembers to add `pb-2 first:pt-4`. If the
  # sidebar ever feels wrong, change this one place.
  attr :label, :string, default: nil
  attr :class, :string, default: ""
  slot :actions, doc: "optional trailing controls next to the section label"
  slot :inner_block, required: true

  def section(assigns) do
    ~H"""
    <section class={["px-3 pt-4 pb-1 first:pt-3", @class]}>
      <div :if={@label || @actions != []} class="flex items-center justify-between px-2 mb-1.5 md:mb-1 min-h-6">
        <h3 :if={@label} class="text-xs uppercase tracking-wider text-zinc-500 dark:text-zinc-400 font-semibold">
          {@label}
        </h3>
        <div :if={@actions != []} class="flex-none">{render_slot(@actions)}</div>
      </div>
      <div class="space-y-px">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  # --- Row: the one and only list-item shape ---
  #
  # Every interactive item in any sidebar goes through this. Fixed
  # row height (min-h-8 desktop, min-h-11 mobile) so trailing slots
  # with port buttons / badges can't push row height up and create
  # the "services are taller than agents" problem we had.
  #
  # Use one of: navigate, patch, phx_click. Non-link variant: just
  # render children inside <.row as={:div}>...
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :phx_click, :string, default: nil
  attr :phx_value, :map, default: %{}
  attr :selected, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :aria_label, :string, default: nil
  attr :class, :string, default: ""
  attr :as, :atom, default: nil, doc: "`:div` to render a non-interactive row"
  slot :inner_block, required: true

  def row(assigns) do
    assigns =
      assign(assigns, :base_class, [
        "flex items-center gap-2 px-2 min-h-11 md:min-h-8 rounded text-sm transition-colors",
        if(assigns.selected,
          do: "bg-white dark:bg-zinc-800 shadow-sm",
          else: "hover:bg-white/60 dark:hover:bg-zinc-800/40"
        ),
        if(assigns.disabled, do: "opacity-60 cursor-not-allowed"),
        assigns.class
      ])

    cond do
      assigns.as == :div ->
        ~H"""
        <div class={@base_class} aria-label={@aria_label}>
          {render_slot(@inner_block)}
        </div>
        """

      assigns.navigate || assigns.patch ->
        ~H"""
        <.link
          navigate={@navigate}
          patch={@patch}
          aria-label={@aria_label}
          aria-current={if @selected, do: "true"}
          class={["focus-ring" | @base_class]}
        >
          {render_slot(@inner_block)}
        </.link>
        """

      assigns.phx_click ->
        ~H"""
        <button
          type="button"
          phx-click={@phx_click}
          {build_phx_values(@phx_value)}
          disabled={@disabled}
          aria-label={@aria_label}
          aria-current={if @selected, do: "true"}
          class={["focus-ring w-full text-left" | @base_class]}
        >
          {render_slot(@inner_block)}
        </button>
        """

      true ->
        ~H"""
        <div class={@base_class} aria-label={@aria_label}>
          {render_slot(@inner_block)}
        </div>
        """
    end
  end

  defp build_phx_values(values) when is_map(values) do
    for {k, v} <- values, into: %{}, do: {"phx-value-#{k}", v}
  end

  # --- Dot: status indicator ---
  attr :class, :string, required: true
  attr :size, :atom, default: :sm, values: [:sm, :md]

  def dot(assigns) do
    assigns = assign(assigns, :size_class, if(assigns.size == :md, do: "w-2 h-2", else: "w-1.5 h-1.5"))

    ~H"""
    <span class={["rounded-full flex-none", @size_class, @class]} aria-hidden="true"></span>
    """
  end

  # --- Info row: label / value pair (used in Agent Context) ---
  #
  # Same horizontal padding as `row/1` and `section/1`'s label so that
  # labels, row contents, and key/value pairs all share one left edge.
  # That's the alignment the user expects when scanning a sidebar.
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :class, :string, default: nil
  attr :monospace, :boolean, default: false

  def info_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3 px-2 min-h-7 md:min-h-6 text-xs">
      <span class="text-zinc-500 dark:text-zinc-500 flex-none">{@label}</span>
      <span class={[
        "truncate",
        if(@monospace, do: "font-mono"),
        @class || "font-medium text-zinc-700 dark:text-zinc-300"
      ]}>
        {@value}
      </span>
    </div>
    """
  end

  # --- Empty / loading hint within a section ---
  attr :text, :string, required: true

  def empty(assigns) do
    ~H"""
    <p class="px-2 py-1 text-xs text-zinc-400 dark:text-zinc-500">{@text}</p>
    """
  end
end
