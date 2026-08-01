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
    <%!-- pb-0: the between-groups gap is the NEXT section's pt-4 alone (16px),
    matching the workspace rail's group_label pt-4 — pb-1 + pt-4 gave the
    details zone a visibly looser rhythm than the rail above it. The LAST
    section gets pb-4 (last-of-type — the action bar is a sibling DIV,
    so :last-child never matches) so the zone's bottom breathes like its top (the
    connection block sat flush against the action bar). --%>
    <section class={[
      @variant == :section && "pt-4 first:pt-3 last-of-type:pb-4",
      @variant == :sub && "pt-2.5 md:pt-2",
      "px-3 pb-0",
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
              "text-sm md:text-xs tracking-wider text-zinc-500 dark:text-zinc-400 font-semibold",
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
  attr :status, :string, default: nil, doc: "status word shown as a pill (e.g. \"Running\")"

  attr :status_class, :string,
    default: "bg-zinc-500/10 text-zinc-600 dark:text-zinc-300",
    doc: "pill classes (bg + text) for the status badge"

  slot :facts, doc: "a compact live-facts line under the name"

  attr :expandable, :boolean,
    default: false,
    doc: """
    Show a collapse chevron, right-aligned in the eyebrow row. Only pass true
    when there IS detail to reveal — a chevron that opens nothing is worse than
    no chevron, so panels without extra detail (History, Changes) omit it and
    let the facts line carry everything.
    """

  attr :expanded, :boolean, default: false
  attr :toggle_event, :string, default: nil, doc: "phx-click event for the chevron"

  slot :collapsed_actions,
    doc: """
    Compact icon+label actions shown while collapsed. Keep it to two or three:
    a bare icon with no label is a guessing game, and a row of them stops being
    a shortcut and becomes a second toolbar. The full labelled set lives in the
    body when expanded.
    """

  def detail_hero(assigns) do
    ~H"""
    <%!-- NO border by default — a sticky element only needs a divider when content
    is actually scrolling under it. The opaque (/95) blurred bg covers any
    scrolling content; the `StickyEdge` hook adds a subtle shadow ONLY while
    there's content scrolled under it, so a short (non-scrolling) panel reads
    as one cohesive card with no lines. --%>
    <div
      data-sticky-edge="top"
      class="sticky top-0 z-10 bg-zinc-50/95 dark:bg-zinc-900/95 backdrop-blur-sm px-4 pt-3.5 md:pt-3 pb-2.5 md:pb-2"
    >
      <%!-- THE WHOLE HEADER is the toggle — eyebrow, title and stats together,
    not a 32px chevron. A big target is easier to hit on a phone and it
    reads as "this block opens" rather than "hunt for the arrow". The
    chevron stays purely as the affordance that says so.
    `:if` on a <button> vs a plain <div> so a hero with nothing to reveal
    isn't a dead clickable region. --%>
      <%!-- Big tap target, NO hover wash: lighting up the entire header on hover
      made the whole sidebar feel like it was reacting to the cursor. Only the
      chevron brightens, which is enough to say "this opens". --%>
      <.dynamic_tag
        tag_name={(@expandable && @toggle_event && "button") || "div"}
        phx-click={(@expandable && @toggle_event) || nil}
        aria-expanded={(@expandable && @toggle_event && to_string(@expanded)) || nil}
        class={[
          "group/hero w-full text-left",
          (@expandable && @toggle_event && "focus-ring rounded-sm") || ""
        ]}
      >
        <div class="flex items-center gap-2 mb-1 md:mb-0.5">
          <div class="section-label flex-1 min-w-0">
            {@eyebrow}
          </div>
          <svg
            :if={@expandable && @toggle_event}
            viewBox="0 0 20 20"
            fill="currentColor"
            class={[
              "w-4 h-4 flex-none text-zinc-400 dark:text-zinc-500 transition-all",
              "group-hover/hero:text-zinc-700 dark:group-hover/hero:text-zinc-200",
              @expanded && "rotate-180"
            ]}
            aria-hidden="true"
          >
            <path
              fill-rule="evenodd"
              d="M5.23 7.21a.75.75 0 0 1 1.06.02L10 11.17l3.71-3.94a.75.75 0 1 1 1.08 1.04l-4.25 4.5a.75.75 0 0 1-1.08 0l-4.25-4.5a.75.75 0 0 1 .02-1.06Z"
              clip-rule="evenodd"
            />
          </svg>
        </div>
        <%!-- The TITLE row: a big, bold name that clearly dominates everything the
    card shows/controls, with the status as a colored pill flush-right. --%>
        <div class="flex items-center gap-2">
          <span :if={@dot} class={"w-2.5 h-2.5 rounded-full flex-none #{@dot}"} aria-hidden="true"></span>
          <h2 class="flex-1 min-w-0 text-lg font-semibold leading-tight text-zinc-900 dark:text-zinc-100 truncate">
            {@name}
          </h2>
          <span
            :if={@status}
            class={["flex-none text-xs font-semibold px-2 py-0.5 rounded-full", @status_class]}
          >
            {@status}
          </span>
        </div>
        <div :if={@facts != []} class="mt-1 text-sm text-zinc-500 dark:text-zinc-400 truncate">
          {render_slot(@facts)}
        </div>
      </.dynamic_tag>
      <%!-- Collapsed actions sit BELOW the stats, deliberately far from the
      collapse chevron: side by side, a stray tap meant for "expand" would
      hit an action instead — the same adjacency problem Skip had next to
      Answer. Full-width labelled buttons live in the body when expanded. --%>
      <div
        :if={@collapsed_actions != [] && !@expanded}
        class="mt-2 flex items-center gap-1"
      >
        {render_slot(@collapsed_actions)}
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
      data-sticky-edge="bottom"
      class="sticky bottom-0 z-10 bg-zinc-50/95 dark:bg-zinc-900/95 backdrop-blur-sm px-3 pt-4 pb-3"
    >
      <div :if={@main != []} class="space-y-1.5">{render_slot(@main)}</div>
      <div
        :if={@danger != []}
        class={[
          "mt-2 pt-2 border-t border-zinc-100 dark:border-zinc-800",
          @main == [] && "!mt-0 !pt-0 !border-t-0"
        ]}
      >
        {render_slot(@danger)}
      </div>
    </div>
    <%!-- No buttons at all (e.g. the code volume) → there's no footer to supply
    bottom breathing room, so the last content would butt against the panel
    edge. A small breather fixes the abrupt cut-off. --%>
    <div :if={@main == [] && @danger == []} class="h-4" aria-hidden="true"></div>
    """
  end

  # --- Row: the one and only list-item shape ---
  #
  # Every interactive item in any sidebar goes through this. Fixed
  # row height (min-h-7 desktop, min-h-11 mobile) so trailing slots
  # with port buttons / badges can't push row height up and create
  # the "services are taller than agents" problem we had. Desktop is
  # deliberately denser than mobile — a pointer doesn't need a 44px
  # target, and loose item spacing read as wasted rail (user feedback).
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
        "flex items-center gap-2 px-2 min-h-11 md:min-h-7 rounded-sm text-sm transition-colors",
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
    <div class="flex items-center justify-between gap-3 px-2 min-h-7 md:min-h-5 text-sm md:text-[13px]">
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
