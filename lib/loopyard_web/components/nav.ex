defmodule LoopyardWeb.Components.Nav do
  @moduledoc """
  The site's navigation vocabulary — one set of responsive primitives every
  nav surface composes from, so the top bar, tabs, back-out, and switcher look
  and behave identically whether you're in the workspace, on `/sound`, on a
  `/system` page, or in a detail panel.

  Before this module each surface hand-rolled the same four things (a bordered
  header row, a back arrow, a segmented pill control, the zoom item-switcher).
  They drifted. This is the extraction:

  * `bar/1`  — the top-bar shell: a `flex-none` bordered row with a
  `min-w-0` title zone (`:inner_block`) and a
  `flex-none` `:actions` zone. WHERE you are.
  * `back_button/1`  — the canonical back-out affordance (navigate / patch /
  `onclick="history.back()"`), two sizes.
  * `segmented/1`  — a segmented pill control from a list of link items;
  `seg_item_class/1` is exposed for the rare
  button-based control (e.g. detail level).
  * `section_switcher/1`— the "WHAT am I looking at" row: section tabs + the
  current item + a zoom-out panel of siblings.

  All of it is server-driven markup — the only client behaviour is the switcher's
  `toggle_panel/0` show/hide transition (no round-trip). Responsive by
  construction: the title zone truncates, the actions zone never wraps.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  # ── bar ──────────────────────────────────────────────────────────────────

  @doc """
  The top-bar shell. A `flex-none` bordered header row split into a `min-w-0`
  title zone (`:inner_block` — back button, breadcrumb, page title) and a
  `flex-none` `:actions` zone (sound, nav, overflow menu). The title zone
  truncates; the actions zone holds its size. Used by the workspace mobile
  header, the app header, the `/sound` page, and every detail panel.

  <.bar>
  <.back_button navigate="/" />
  <h1 class="truncate font-semibold">Sound</h1>
  <:actions><.mode_nav id="mode-x" active={:workspaces} /></:actions>
  </.bar>
  """
  attr :height, :string, default: "h-14", doc: "row height, e.g. h-12 (compact) / h-14"
  attr :pad, :string, default: "px-4 md:px-5"
  attr :gap, :string, default: "gap-2", doc: "gap within the title zone"
  attr :border, :boolean, default: true
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true
  slot :actions

  def bar(assigns) do
    ~H"""
    <div
      class={[
        "flex-none flex items-center justify-between gap-2",
        @height,
        @pad,
        @border && "border-b border-zinc-200 dark:border-zinc-700/80",
        @class
      ]}
      {@rest}
    >
      <div class={["flex-1 min-w-0 flex items-center", @gap]}>
        {render_slot(@inner_block)}
      </div>
      <div :if={@actions != []} class="flex-none flex items-center gap-3">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  # ── back_button ──────────────────────────────────────────────────────────

  @doc """
  The canonical back-out affordance: a left-arrow icon button. Renders as a
  live `navigate`/`patch` link when given a target, or a plain `<button>` for
  `onclick="history.back()"` (the `/sound` page, which just pops the stack).

  `size={:sm}` (w-9) suits an inline breadcrumb; the default `:md` (w-11) is a
  proper 44px tap target for a full-bleed header.

  <.back_button navigate="/" />
  <.back_button size={:sm} navigate={@parent_path} />
  <.back_button onclick="history.back()" />
  """
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :label, :string, default: "Back"
  attr :size, :atom, default: :md, values: [:sm, :md]
  attr :rest, :global, include: ~w(onclick)

  def back_button(assigns) do
    assigns =
      assign(assigns, :cls, [
        "focus-ring flex-none inline-flex items-center justify-center rounded-sm text-zinc-500 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800 active:bg-zinc-200 dark:active:bg-zinc-700 transition-colors",
        if(assigns.size == :sm, do: "tap-target w-9 h-9 -ml-1", else: "w-11 h-11 -ml-1.5")
      ])

    ~H"""
    <.link :if={@navigate} navigate={@navigate} aria-label={@label} class={@cls}>
      <.back_arrow />
    </.link>
    <.link :if={@patch} patch={@patch} aria-label={@label} class={@cls}>
      <.back_arrow />
    </.link>
    <button :if={!@navigate && !@patch} type="button" aria-label={@label} class={@cls} {@rest}>
      <.back_arrow />
    </button>
    """
  end

  defp back_arrow(assigns) do
    ~H"""
    <svg viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5" aria-hidden="true">
      <path
        fill-rule="evenodd"
        d="M17 10a.75.75 0 0 1-.75.75H5.612l4.158 3.96a.75.75 0 1 1-1.04 1.08l-5.5-5.25a.75.75 0 0 1 0-1.08l5.5-5.25a.75.75 0 1 1 1.04 1.08L5.612 9.25H16.25A.75.75 0 0 1 17 10Z"
        clip-rule="evenodd"
      />
    </svg>
    """
  end

  @doc """
  A close (✕) affordance for full-screen overlays / global pop-up pages (the
  `/sound` page, the `switcher_sheet/1`). Reads as "dismiss this thing," not
  "navigate back" — the right signal for something that floats over the app.
  Pass `phx-click` (client dismiss) or `onclick="history.back()"` (page-level).

  <.close_button onclick="history.back()" />
  <.close_button phx-click={JS.hide(to: "#sheet")} />
  """
  attr :label, :string, default: "Close"
  attr :rest, :global, include: ~w(onclick)

  def close_button(assigns) do
    ~H"""
    <button
      type="button"
      aria-label={@label}
      class="focus-ring flex-none inline-flex items-center justify-center w-11 h-11 -mr-1.5 rounded-sm text-zinc-500 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800 active:bg-zinc-200 dark:active:bg-zinc-700 transition-colors"
      {@rest}
    >
      <svg viewBox="0 0 20 20" fill="currentColor" class="w-6 h-6" aria-hidden="true">
        <path d="M6.28 5.22a.75.75 0 0 0-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 1 0 1.06 1.06L10 11.06l3.72 3.72a.75.75 0 1 0 1.06-1.06L11.06 10l3.72-3.72a.75.75 0 0 0-1.06-1.06L10 8.94 6.28 5.22Z" />
      </svg>
    </button>
    """
  end

  # ── segmented ────────────────────────────────────────────────────────────

  @doc """
  A segmented pill control built from a list of link items. The active segment
  is a raised white/dark pill; the rest are quiet labels. Each item is a map:

  %{label: "Agents", active?: true, patch: "/…"}  # or navigate:/href:

  <.segmented
  label="Workspace section"
  items={[
  %{label: "Agents", active?: @active == :agents, patch: @agents_href},
  %{label: "Services", active?: @active == :services, patch: @services_href}
  ]}
  />

  For a button-based control (a `phx-click` toggle rather than navigation) use
  `seg_item_class/1` on your own `<button>`s inside a matching container — see
  `LoopyardWeb.Live.WorkspaceLive.Components.Chat.detail_level_control/1`.
  """
  attr :items, :list, required: true
  attr :label, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global

  def segmented(assigns) do
    ~H"""
    <nav
      :if={@items != []}
      class={["inline-flex items-center  bg-zinc-100 dark:bg-zinc-800 p-0.5 flex-none", @class]}
      aria-label={@label}
      {@rest}
    >
      <.link
        :for={item <- @items}
        patch={item[:patch]}
        navigate={item[:navigate]}
        href={item[:href]}
        aria-current={item[:active?] && "page"}
        class={seg_item_class(item[:active?])}
      >
        {item.label}
      </.link>
    </nav>
    """
  end

  @doc """
  Classes for one segment of a `segmented/1` control. Public so a button-based
  segmented control (localStorage-backed detail level, say) shares the exact
  active-pill look without duplicating the tokens.
  """
  def seg_item_class(active?) do
    [
      "focus-ring inline-flex items-center justify-center min-h-[2.5rem] px-3 rounded-sm text-sm font-medium leading-none transition-colors whitespace-nowrap",
      if(active?,
        do: "bg-white dark:bg-zinc-700 text-zinc-900 dark:text-zinc-100 shadow-sm",
        else: "text-zinc-500 dark:text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200"
      )
    ]
  end

  # ── section_switcher ─────────────────────────────────────────────────────

  @doc """
  The "WHAT am I looking at" row + its zoom-out panel. Renders the section tabs
  (`:tabs` slot — usually a `segmented/1`) next to the CURRENT item; tapping the
  current item zooms OUT to a panel of its siblings, pick one to zoom back in.
  Client-side toggle (`toggle_panel/0`), no server round-trip.

  * `current` — `%{label, dot, detail, tone, badge}` or `nil` (row hides the
  trigger when nothing is selected in this section).
  * `groups` — every section at once: `[%{key, title, items}]`, each item
  `%{label, href, active?, dot, detail}`.
  * `:extra`  — optional trailing action per group; receives the group, so a
  caller can add "+ New agent" under Agents only.

  <.section_switcher id="item-switcher" current={@current} groups={@nav_groups}>
  <:extra :let={g}><.link :if={g.key == :agents} patch={@base_path <> "/new"}>+ New agent</.link></:extra>
  </.section_switcher>
  """
  attr :id, :string, default: "item-switcher"
  attr :title, :string, default: "Switch"
  attr :current, :map, default: nil
  # EVERY section at once — `[%{title, key, items}]`. The phone used to carry a
  # tab strip plus a dropdown of only the active tab's siblings: two controls,
  # two taps to cross sections, and each dropdown looked half-empty. One sheet
  # of the whole grouped sidebar is the same information in one gesture.
  attr :groups, :list, default: []
  # When true, a consistent "details" TOGGLE trails the switcher — the ONE
  # affordance for "more about this thing", identical across agents / services /
  # files. It fires `toggle_mobile_detail` (a SERVER assign) which swaps the
  # surface content for the detail panel IN PLACE (flat, in-flow); the state
  # survives navigation, so switching items keeps showing detail until toggled
  # back. `details_open` lights the button while open.
  attr :has_details, :boolean, default: false
  attr :details_open, :boolean, default: false
  slot :extra

  def section_switcher(assigns) do
    ~H"""
    <div class="flex items-center gap-2 px-2 h-16 border-t border-zinc-200/70 dark:border-zinc-700/50">
      <%!-- The current item, minimalist: a status dot (colour IS the state, no
    "Running" text), the name, and a chevron as the sole "tap to switch"
    affordance. No purple Switch pill — the chevron carries it. --%>
      <button
        :if={@current}
        type="button"
        phx-click={toggle_panel(@id)}
        aria-controls={@id}
        aria-haspopup="dialog"
        aria-label={"#{@title} — currently #{@current.label}"}
        class="focus-ring flex-1 min-w-0 flex items-center gap-2 min-h-[2.75rem] px-3 rounded-sm text-left hover:bg-zinc-100 dark:hover:bg-zinc-800/60 active:bg-zinc-200 dark:active:bg-zinc-700/60 transition-colors"
      >
        <span class={["w-2 h-2 rounded-full flex-none", @current.dot]}></span>
        <span class="flex-1 min-w-0 truncate font-semibold text-zinc-900 dark:text-zinc-100">
          {@current.label}
        </span>
        <.chevron_down class="w-4 h-4 text-zinc-500 dark:text-zinc-400 flex-none" />
      </button>
      <%!-- Details TOGGLE for the selected thing (agent usage / service actions /
    volume info). Same icon + behaviour everywhere; sits with the switcher
    because it expands what the switcher names. Tap → the detail replaces
    the surface in place (flat, scrolls with the viewport); tap → back. --%>
      <button
        :if={@current && @has_details}
        id="section-details-toggle"
        type="button"
        phx-click="toggle_mobile_detail"
        aria-label="Toggle details"
        aria-pressed={to_string(@details_open)}
        class={[
          "focus-ring flex-none inline-flex items-center justify-center w-11 h-11 rounded-sm transition-colors",
          if(@details_open,
            do: "bg-violet-100 dark:bg-violet-500/15 text-violet-600 dark:text-violet-400",
            else:
              "text-zinc-500 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800 active:bg-zinc-200 dark:active:bg-zinc-700"
          )
        ]}
      >
        <.details_icon class="w-5 h-5" />
      </button>
    </div>

    <.switcher_sheet id={@id} title={@title}>
      <:current :if={@current}>
        <span class={["w-2 h-2 rounded-full flex-none", @current.dot]}></span>
        <span class="flex-1 min-w-0 truncate font-semibold text-zinc-900 dark:text-zinc-100">
          {@current.label}
        </span>
        <span :if={@current[:detail]} class={["flex-none truncate", @current[:tone]]}>
          {@current.detail}
        </span>
      </:current>
      <div :for={group <- @groups} class="pt-4 first:pt-0">
        <div class="section-label px-3 pb-1">{group.title}</div>
        <.link
          :for={item <- group.items}
          patch={item.href}
          phx-click={JS.hide(to: "##{@id}")}
          class={sheet_row_class(item[:active?])}
        >
          <span class={["w-2.5 h-2.5 rounded-full flex-none", item.dot]}></span>
          <span class="flex-1 min-w-0 truncate">{item.label}</span>
          <%!-- Check BEFORE the status so the status stays flush-right on every
      row — a trailing check shifted the active row's status left and
      broke alignment with the others. --%>
          <.check :if={item[:active?]} />
          <%!-- Status same size as the name, muted + right-aligned (matches the
      switcher trigger above). --%>
          <span :if={item[:detail]} class="flex-none truncate text-zinc-500 dark:text-zinc-400">
            {item.detail}
          </span>
        </.link>
        {render_slot(@extra, group)}
      </div>
    </.switcher_sheet>
    """
  end

  # ── crumb + menu (breadcrumb-as-switcher) ────────────────────────────────

  @doc """
  One breadcrumb segment that doubles as a switcher trigger. When `switch?` is
  true it's a button that opens the full-screen `switcher_sheet/1` with the
  matching `id`. Otherwise it's a plain link (`href`) or, for the current page,
  plain text.

  Pair it with a `switcher_sheet/1` of the same `id`:

  <.crumb id="nav-switcher" label={@ws} current switch?={@many?} />
  <.switcher_sheet id="nav-switcher" title="Switch">…rows…</.switcher_sheet>
  """
  attr :id, :string, default: nil
  attr :label, :string, required: true
  attr :current, :boolean, default: false, doc: "styled solid (current page) vs muted (ancestor)"
  attr :switch?, :boolean, default: false
  attr :href, :string, default: nil
  # A trail of switch crumbs (project / workspace) all open the SAME switcher, so
  # only ONE needs the chevron — set `chevron={false}` on the leading crumbs.
  # They stay tappable; the single chevron on the last crumb is the affordance.
  attr :chevron, :boolean, default: true

  def crumb(assigns) do
    ~H"""
    <button
      :if={@switch?}
      type="button"
      phx-click={toggle_panel(@id)}
      aria-controls={@id}
      aria-haspopup="dialog"
      aria-label={"Switch — currently #{@label}"}
      class={[
        "focus-ring min-w-0 inline-flex items-center gap-0.5 rounded-sm",
        crumb_label_class(@current)
      ]}
    >
      <span class="truncate">{@label}</span>
      <.chevron_down :if={@chevron} class="w-4 h-4 flex-none opacity-60" />
    </button>
    <.link :if={!@switch? && @href} navigate={@href} class={crumb_label_class(@current)}>
      {@label}
    </.link>
    <span :if={!@switch? && !@href} class={crumb_label_class(@current)}>{@label}</span>
    """
  end

  defp crumb_label_class(true), do: "truncate font-semibold text-zinc-900 dark:text-zinc-100"

  defp crumb_label_class(false),
    do:
      "truncate text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-100 transition-colors"

  @doc """
  A FULL-SCREEN switcher sheet — the mobile switcher pattern. NEVER a floating
  pop-over (those don't work on a phone: cramped, overlap content, hard to
  dismiss). Hidden until a trigger (`crumb/1` / `toggle_panel/1`) opens it; then
  it takes the whole screen with a titled header, a big close (✕), and multiple
  easy exits (tap ✕, tap the backdrop, or pick a row). The rows are the caller's
  (`:inner_block`) — build them with `sheet_row_class/1` and a `JS.hide(to: "#id")`
  on tap so selecting closes the sheet.

  <.switcher_sheet id="nav-switcher" title="Switch">
  <.link :for={…} navigate={…} phx-click={JS.hide(to: "#nav-switcher")}
  class={Nav.sheet_row_class(active?)}>…</.link>
  </.switcher_sheet>
  """
  attr :id, :string, required: true
  attr :title, :string, required: true

  slot :current,
    doc:
      "The currently-selected item. Rendered as the sticky tap-to-close header so " <>
        "the switcher toggles: tap the same thing to go back. Falls back to the title."

  slot :inner_block, required: true

  def switcher_sheet(assigns) do
    ~H"""
    <div
      id={@id}
      class="hidden fixed inset-0 z-[60]"
      role="dialog"
      aria-modal="true"
      aria-label={@title}
    >
      <div
        class="absolute inset-0 bg-zinc-900/50 backdrop-blur-sm"
        phx-click={toggle_panel(@id)}
        aria-hidden="true"
      >
      </div>
      <div class="absolute inset-0 flex flex-col bg-brand-paper dark:bg-brand-ink safe-area-x">
        <%!-- The current selection AS a tap-to-close header: tapping it (or the
    backdrop) toggles the sheet shut — so open-then-tap-the-same-thing
    "goes back", like a toggle. It's flex-none at the top, so it stays put
    while the selectable options scroll beneath. The up-chevron mirrors the
    trigger's down-chevron: down to open, up to collapse. Falls back to the
    plain title when no :current is given. --%>
        <button
          type="button"
          phx-click={toggle_panel(@id)}
          aria-label={"Close #{@title}"}
          class="flex-none flex items-center justify-center gap-2 h-14 px-4 w-full border-b border-zinc-200 dark:border-zinc-700/80"
        >
          <%!-- Mirrors the trigger it opens from: same h-14, the same thing
    centred, and the chevron IMMEDIATELY BESIDE the title — exactly where
    the closed state puts it. Parking the chevron in a right-hand cell
    made it fly from next to the title to the screen edge on open, which
    is the shift. Title + chevron travel as one centred unit, so only the
    arrow flips (v to ^). --%>
          <div :if={@current != []} class="min-w-0 flex items-center gap-2">
            {render_slot(@current)}
          </div>
          <h2
            :if={@current == []}
            class="min-w-0 text-lg font-semibold text-zinc-900 dark:text-zinc-100 truncate"
          >
            {@title}
          </h2>
          <.chevron_down class="w-5 h-5 flex-none text-zinc-500 dark:text-zinc-400 rotate-180" />
        </button>
        <div class="flex-1 overflow-y-auto overscroll-contain p-2 space-y-0.5">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  A bottom SHEET — the mobile "share-sheet" pattern. Slides up from the bottom to
  a content-sized height and is dismissed by a swipe-down on the grab handle, a tap
  on the backdrop, or picking an action. Use it for actions/details on mobile where
  a full-screen switcher is overkill. Open from a trigger with
  `phx-click={Nav.open_sheet("id")}`; the `BottomSheet` JS hook owns the slide +
  swipe. `:current` is an optional header row (name/status); rows go in the body.
  """
  attr :id, :string, required: true
  attr :title, :string, default: nil
  slot :current
  slot :inner_block, required: true

  def bottom_sheet(assigns) do
    ~H"""
    <div
      id={@id}
      class="hidden fixed inset-0 z-[60]"
      role="dialog"
      aria-modal="true"
      aria-label={@title}
    >
      <div
        class="absolute inset-0 bg-zinc-900/60 backdrop-blur-sm"
        phx-click={close_sheet(@id)}
        aria-hidden="true"
      >
      </div>
      <div
        id={"#{@id}-panel"}
        phx-hook="BottomSheet"
        data-sheet={"##{@id}"}
        class="absolute inset-x-0 bottom-0 translate-y-full flex flex-col max-h-[85dvh]  bg-brand-paper dark:bg-brand-ink shadow-2xl shadow-black/30 safe-area-x transition-transform duration-300 ease-out motion-reduce:transition-none"
      >
        <%!-- Grab handle + optional header = the DRAG ZONE: swipe it down to
    dismiss. The body below scrolls independently. --%>
        <div data-sheet-drag class="flex-none touch-none select-none">
          <div class="flex justify-center pt-2.5 pb-1">
            <div class="w-10 h-1.5 rounded-full bg-zinc-300 dark:bg-zinc-600"></div>
          </div>
          <div :if={@current != []} class="flex items-center gap-2 px-4 pb-2">
            {render_slot(@current)}
          </div>
        </div>
        <div class="overflow-y-auto overscroll-contain px-3 pb-[max(1rem,env(safe-area-inset-bottom))]">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  @doc "Open a `bottom_sheet/1` (the BottomSheet hook slides it up)."
  def open_sheet(id), do: JS.dispatch("sheet:open", to: "##{id}-panel")

  @doc "Close a `bottom_sheet/1` (slide it down, then hide)."
  def close_sheet(id), do: JS.dispatch("sheet:close", to: "##{id}-panel")

  @doc """
  Classes for a big-tap-target row inside a `switcher_sheet/1`. Active row is a
  violet highlight; comfortable 3.25rem height for a thumb.
  """
  def sheet_row_class(active?) do
    [
      "focus-ring flex items-center gap-3 min-h-[3.25rem] px-3  text-base transition-colors",
      if(active?,
        do: "bg-violet-100 dark:bg-violet-500/15 text-zinc-900 dark:text-zinc-100 font-semibold",
        else:
          "text-zinc-700 dark:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800 active:bg-zinc-200 dark:active:bg-zinc-700"
      )
    ]
  end

  @doc """
  Client-side toggle for a switcher panel: a SLIDE-DOWN + fade, so the list drops
  in from the top ("here's everything, in place") and retracts upward on close.
  A pure CSS/JS transition — no navigation — so it never touches server/client
  state; opening a switcher can't lose your place. `motion-reduce` honors
  prefers-reduced-motion (the classes collapse to an instant show/hide).
  """
  def toggle_panel(id \\ "item-switcher") do
    JS.toggle(
      to: "##{id}",
      in:
        {"transition ease-out duration-300 motion-reduce:transition-none",
         "opacity-0 -translate-y-6", "opacity-100 translate-y-0"},
      out:
        {"transition ease-in duration-200 motion-reduce:transition-none",
         "opacity-100 translate-y-0", "opacity-0 -translate-y-6"}
    )
  end

  # A violet check for the active row in a switcher sheet.
  defp check(assigns) do
    ~H"""
    <svg
      viewBox="0 0 20 20"
      fill="currentColor"
      class="w-5 h-5 flex-none text-violet-600 dark:text-violet-400"
      aria-hidden="true"
    >
      <path
        fill-rule="evenodd"
        d="M16.7 5.3a1 1 0 0 1 0 1.4l-7.5 7.5a1 1 0 0 1-1.4 0l-3.5-3.5a1 1 0 1 1 1.4-1.4l2.8 2.79 6.8-6.79a1 1 0 0 1 1.4 0Z"
        clip-rule="evenodd"
      />
    </svg>
    """
  end

  @doc """
  The ONE "this opens a switcher" chevron. Public because any surface that
  triggers a switcher must draw the same mark — a second hand-rolled chevron is
  how the affordance stops reading as one affordance.
  """
  attr :class, :string, default: "w-4 h-4"

  def chevron_down(assigns) do
    ~H"""
    <svg viewBox="0 0 20 20" fill="currentColor" class={@class} aria-hidden="true">
      <path
        fill-rule="evenodd"
        d="M5.22 8.22a.75.75 0 0 1 1.06 0L10 11.94l3.72-3.72a.75.75 0 1 1 1.06 1.06l-4.25 4.25a.75.75 0 0 1-1.06 0L5.22 9.28a.75.75 0 0 1 0-1.06Z"
        clip-rule="evenodd"
      />
    </svg>
    """
  end

  @doc """
  The 'toggle details' icon — a panel docked at the bottom of a screen. The
  button it marks pulls up the selected item's full panel (status + info +
  its controls), so it's NOT an (i) info glyph and NOT a generic menu/overflow:
  it literally shows a bottom panel appearing. Reads at a glance as "bring up
  the panel for this."
  """
  attr :class, :string, default: "w-5 h-5"

  def details_icon(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" fill="none" class={@class} aria-hidden="true">
      <rect
        x="3.25"
        y="4.75"
        width="17.5"
        height="14.5"
        rx="3"
        stroke="currentColor"
        stroke-width="1.7"
      />
      <path
        d="M3.25 14.25h17.5v2a3 3 0 0 1-3 3H6.25a3 3 0 0 1-3-3z"
        fill="currentColor"
      />
    </svg>
    """
  end
end
