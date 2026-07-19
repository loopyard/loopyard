defmodule LoopyardWeb.Components.SideNav do
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
  # `:section` (L2) is a top-level group; `:sub` (L3) is a group nested inside
  # another section (e.g. Usage/Docker/Tools inside "Details") — a quieter,
  # lighter label so the hierarchy reads at a glance.
  attr :variant, :atom, default: :section, values: [:section, :sub]
  slot :actions, doc: "optional trailing controls next to the section label"
  slot :inner_block, required: true

  def section(assigns) do
    ~H"""
    <section class={[
      @variant == :section && "pt-4 first:pt-3",
      @variant == :sub && "pt-2.5",
      "px-3 pb-1",
      @class
    ]}>
      <div
        :if={@label || @actions != []}
        class="flex items-center justify-between px-2 mb-1.5 md:mb-1 min-h-6"
      >
        <h3
          :if={@label}
          class={[
            @variant == :section &&
              "text-sm tracking-wider text-zinc-500 dark:text-zinc-400 font-semibold",
            @variant == :sub &&
              "text-xs tracking-wide text-zinc-500 dark:text-zinc-400 font-medium",
            "uppercase"
          ]}
        >
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

  # --- Detail title: the ONE header shape for a selected entity's detail pane ---
  #
  # Shared by the agent / service / volume detail panels (Zone B of the workspace
  # rail) so all three read identically: a full-bleed top divider from the nav
  # above, an uppercase eyebrow naming the KIND, then the entity name (with an
  # optional status dot). The px-5 inset == the section gutter (`section` px-3 +
  # its header px-2 = 20px), so the eyebrow + name line up EXACTLY with every
  # section label and info row below. Change the gutter in one place: here.
  attr :eyebrow, :string, required: true
  attr :name, :string, required: true
  attr :dot, :string, default: nil, doc: "dot color class (e.g. \"bg-emerald-500\"), or nil"
  slot :trailing, doc: "optional controls aligned to the right of the name row"

  def detail_title(assigns) do
    ~H"""
    <div class="border-t border-zinc-200 dark:border-zinc-700/80 pt-3 pb-2 mb-1">
      <div class="px-5">
        <div class="text-xs font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
          {@eyebrow}
        </div>
        <div class="flex items-center gap-2 mt-0.5">
          <span :if={@dot} class={"w-2 h-2 rounded-full flex-none #{@dot}"} aria-hidden="true"></span>
          <h3 class="flex-1 min-w-0 text-base font-semibold text-zinc-900 dark:text-zinc-100 truncate">
            {@name}
          </h3>
          <div :if={@trailing != []} class="flex-none">{render_slot(@trailing)}</div>
        </div>
      </div>
    </div>
    """
  end

  # --- Detail hero: the sticky, expanded header for a selected entity ---
  #
  # The top of the detail zone (Zone B). `sticky top-0` so it PINS while the
  # detail scrolls — you never lose which agent/service/volume you're looking at
  # or its live status. Mirrors the nav row above (dot + name) but bigger, and
  # carries a `:facts` slot for the live numbers (model · tokens · port · size…).
  # Opaque + blurred bg so scrolling content passes cleanly underneath.
  attr :eyebrow, :string, required: true
  attr :name, :string, required: true
  attr :dot, :string, default: nil, doc: "dot color class (e.g. \"bg-emerald-500\"), or nil"
  attr :status, :string, default: nil, doc: "status word shown flush-right (e.g. \"Running\")"
  attr :status_class, :string, default: "text-zinc-500 dark:text-zinc-400"
  slot :facts, doc: "a compact live-facts line under the name"

  def detail_hero(assigns) do
    ~H"""
    <div class="sticky top-0 z-10 bg-zinc-50/95 dark:bg-zinc-900/95 backdrop-blur-sm border-b border-zinc-200 dark:border-zinc-700/80 px-5 pt-3 pb-2.5">
      <div class="text-xs font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400">
        {@eyebrow}
      </div>
      <div class="flex items-center gap-2 mt-0.5">
        <span :if={@dot} class={"w-2 h-2 rounded-full flex-none #{@dot}"} aria-hidden="true"></span>
        <h3 class="flex-1 min-w-0 text-base font-semibold text-zinc-900 dark:text-zinc-100 truncate">
          {@name}
        </h3>
        <span :if={@status} class={["flex-none text-sm font-medium", @status_class]}>{@status}</span>
      </div>
      <div :if={@facts != []} class="mt-1 text-sm text-zinc-500 dark:text-zinc-400 truncate">
        {render_slot(@facts)}
      </div>
    </div>
    """
  end

  # --- Action bar: the sticky footer where a panel's buttons live ---
  #
  # `sticky bottom-0` so the actions PIN to the bottom of the detail zone. The
  # `:main` slot holds operational buttons (control_btn), the optional `:danger`
  # slot holds a destructive action rendered BELOW a hairline divider — reachable
  # but set apart. Renders nothing when both slots are empty (e.g. code volume).
  # Sticky (not a flex-locked footer) so on a too-short viewport it just scrolls
  # into view with the content instead of eating the whole panel.
  slot :main, doc: "operational buttons"
  slot :danger, doc: "a destructive action, set apart below a divider"

  def action_bar(assigns) do
    ~H"""
    <div
      :if={@main != [] || @danger != []}
      class="sticky bottom-0 z-10 bg-zinc-50/95 dark:bg-zinc-900/95 backdrop-blur-sm border-t border-zinc-200 dark:border-zinc-700/80 px-3 py-2.5"
    >
      <div :if={@main != []} class="space-y-1.5">{render_slot(@main)}</div>
      <div
        :if={@danger != []}
        class={["mt-2 pt-2 border-t border-zinc-100 dark:border-zinc-800", @main == [] && "!mt-0 !pt-0 !border-t-0"]}
      >
        {render_slot(@danger)}
      </div>
    </div>
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
  attr :id, :string, default: nil
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
        <div id={@id} class={@base_class} aria-label={@aria_label}>
          {render_slot(@inner_block)}
        </div>
        """

      assigns.navigate || assigns.patch ->
        ~H"""
        <.link
          id={@id}
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
          id={@id}
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
        <div id={@id} class={@base_class} aria-label={@aria_label}>
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
    assigns =
      assign(assigns, :size_class, if(assigns.size == :md, do: "w-2 h-2", else: "w-1.5 h-1.5"))

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
    <div class="flex items-center justify-between gap-3 px-2 min-h-7 md:min-h-6 text-sm">
      <span class="text-zinc-500 dark:text-zinc-400 flex-none">{@label}</span>
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
    <p class="px-2 py-1 text-sm text-zinc-500 dark:text-zinc-400">{@text}</p>
    """
  end
end
