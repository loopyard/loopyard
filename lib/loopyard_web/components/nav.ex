defmodule LoopyardWeb.Components.Nav do
  @moduledoc """
  The site's navigation vocabulary — one set of responsive primitives every
  nav surface composes from, so the top bar, tabs, back-out, and switcher look
  and behave identically whether you're in the workspace, on `/sound`, on a
  `/system` page, or in a detail panel.

  Before this module each surface hand-rolled the same four things (a bordered
  header row, a back arrow, a segmented pill control, the zoom item-switcher).
  They drifted. This is the extraction:

    * `bar/1`             — the top-bar shell: a `flex-none` bordered row with a
                            `min-w-0` title zone (`:inner_block`) and a
                            `flex-none` `:actions` zone. WHERE you are.
    * `back_button/1`     — the canonical back-out affordance (navigate / patch /
                            `onclick="history.back()"`), two sizes.
    * `segmented/1`       — a segmented pill control from a list of link items;
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
        <:actions><.sound_control /></:actions>
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
        "flex-none inline-flex items-center justify-center rounded-lg text-zinc-500 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800 active:bg-zinc-200 dark:active:bg-zinc-700 transition-colors",
        if(assigns.size == :sm, do: "w-9 h-9 -ml-1", else: "w-11 h-11 -ml-1.5")
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
    <svg viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5">
      <path
        fill-rule="evenodd"
        d="M17 10a.75.75 0 0 1-.75.75H5.612l4.158 3.96a.75.75 0 1 1-1.04 1.08l-5.5-5.25a.75.75 0 0 1 0-1.08l5.5-5.25a.75.75 0 1 1 1.04 1.08L5.612 9.25H16.25A.75.75 0 0 1 17 10Z"
        clip-rule="evenodd"
      />
    </svg>
    """
  end

  # ── segmented ────────────────────────────────────────────────────────────

  @doc """
  A segmented pill control built from a list of link items. The active segment
  is a raised white/dark pill; the rest are quiet labels. Each item is a map:

      %{label: "Agents", active?: true, patch: "/…"}   # or navigate:/href:

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
      class={["inline-flex items-center rounded-xl bg-zinc-100 dark:bg-zinc-800 p-0.5 flex-none", @class]}
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
      "inline-flex items-center justify-center min-h-[2.5rem] px-3 rounded-lg text-sm font-medium leading-none transition-colors whitespace-nowrap",
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
    * `items`   — sibling rows: `%{label, href, active?, dot, detail}`. The
      Switch pill only appears when there's more than one to switch to.
    * `:extra`  — optional trailing action(s) in the panel (e.g. "+ New agent").

      <.section_switcher id="item-switcher" current={@current} items={@items}>
        <:tabs><.segmented items={@section_tabs} label="Workspace section" /></:tabs>
        <:extra><.link patch={@base_path <> "/new"}>+ New agent</.link></:extra>
      </.section_switcher>
  """
  attr :id, :string, default: "item-switcher"
  attr :title, :string, default: "Switch"
  attr :current, :map, default: nil
  attr :items, :list, default: []
  slot :tabs
  slot :extra

  def section_switcher(assigns) do
    ~H"""
    <div class="flex items-center gap-2 px-2 h-16 border-t border-zinc-200/70 dark:border-zinc-700/50">
      {render_slot(@tabs)}
      <button
        :if={@current}
        type="button"
        phx-click={toggle_panel(@id)}
        aria-controls={@id}
        class="flex-1 min-w-0 flex items-center gap-2 min-h-[2.75rem] px-3 rounded-lg text-left hover:bg-zinc-100 dark:hover:bg-zinc-800/60 active:bg-zinc-200 dark:active:bg-zinc-700/60 transition-colors"
      >
        <span class={["w-2 h-2 rounded-full flex-none", @current.dot]}></span>
        <span class="font-semibold text-zinc-900 dark:text-zinc-100 truncate">{@current.label}</span>
        <span :if={@current[:detail]} class={["text-sm truncate", @current[:tone]]}>
          {@current.detail}
        </span>
        <span
          :if={@current[:badge]}
          class="inline-flex items-center gap-1 text-sm text-zinc-400 dark:text-zinc-500 flex-none"
        >
          <span class="w-1.5 h-1.5 rounded-full bg-amber-500"></span>{@current.badge}
        </span>
        <span class="flex-1"></span>
        <%!-- Switch pill only when there's somewhere to switch to; a lone item
             gets a quiet chevron. --%>
        <span
          :if={length(@items) > 1}
          class="inline-flex items-center gap-1 flex-none rounded-md px-2 py-1 text-sm font-medium text-violet-600 dark:text-violet-400 bg-violet-50 dark:bg-violet-500/10"
        >
          Switch <.chevron_down class="w-4 h-4" />
        </span>
        <.chevron_down
          :if={length(@items) <= 1}
          class="w-4 h-4 text-zinc-300 dark:text-zinc-600 flex-none"
        />
      </button>
    </div>

    <.switcher_sheet id={@id} title={@title}>
      <.link
        :for={item <- @items}
        patch={item.href}
        phx-click={JS.hide(to: "##{@id}")}
        class={sheet_row_class(item[:active?])}
      >
        <span class={["w-2.5 h-2.5 rounded-full flex-none", item.dot]}></span>
        <span class="truncate">{item.label}</span>
        <span :if={item[:detail]} class="text-sm text-zinc-400 dark:text-zinc-500 truncate">
          {item.detail}
        </span>
        <span class="flex-1"></span>
        <.check :if={item[:active?]} />
      </.link>
      {render_slot(@extra)}
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

  def crumb(assigns) do
    ~H"""
    <button
      :if={@switch?}
      type="button"
      phx-click={toggle_panel(@id)}
      aria-controls={@id}
      aria-haspopup="dialog"
      class={["min-w-0 inline-flex items-center gap-0.5 rounded", crumb_label_class(@current)]}
    >
      <span class="truncate">{@label}</span>
      <.chevron_down class="w-3.5 h-3.5 flex-none opacity-60" />
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
      <div class="absolute inset-0 bg-zinc-900/50 backdrop-blur-sm" phx-click={JS.hide(to: "##{@id}")}>
      </div>
      <div class="absolute inset-0 flex flex-col bg-white dark:bg-zinc-900 safe-area-x">
        <div class="flex-none flex items-center justify-between h-14 px-4 border-b border-zinc-200 dark:border-zinc-700/80">
          <h2 class="text-lg font-semibold text-zinc-900 dark:text-zinc-100 truncate">{@title}</h2>
          <button
            type="button"
            phx-click={JS.hide(to: "##{@id}")}
            aria-label="Close"
            class="flex-none inline-flex items-center justify-center w-11 h-11 -mr-1.5 rounded-lg text-zinc-500 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800 active:bg-zinc-200 dark:active:bg-zinc-700 transition-colors"
          >
            <svg viewBox="0 0 20 20" fill="currentColor" class="w-6 h-6">
              <path d="M6.28 5.22a.75.75 0 0 0-1.06 1.06L8.94 10l-3.72 3.72a.75.75 0 1 0 1.06 1.06L10 11.06l3.72 3.72a.75.75 0 1 0 1.06-1.06L11.06 10l3.72-3.72a.75.75 0 0 0-1.06-1.06L10 8.94 6.28 5.22Z" />
            </svg>
          </button>
        </div>
        <div class="flex-1 overflow-y-auto overscroll-contain p-2 space-y-0.5">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Classes for a big-tap-target row inside a `switcher_sheet/1`. Active row is a
  violet highlight; comfortable 3.25rem height for a thumb.
  """
  def sheet_row_class(active?) do
    [
      "flex items-center gap-3 min-h-[3.25rem] px-3 rounded-xl text-base transition-colors",
      if(active?,
        do: "bg-violet-100 dark:bg-violet-500/15 text-zinc-900 dark:text-zinc-100 font-semibold",
        else:
          "text-zinc-700 dark:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800 active:bg-zinc-200 dark:active:bg-zinc-700"
      )
    ]
  end

  @doc """
  Client-side toggle for a switcher panel, with a scale/fade so opening reads as
  "zoom out to the list" and closing as "zoom back into the selection".
  """
  def toggle_panel(id \\ "item-switcher") do
    JS.toggle(
      to: "##{id}",
      in:
        {"transition ease-out duration-200", "opacity-0 -translate-y-1 scale-[0.98]",
         "opacity-100 translate-y-0 scale-100"},
      out:
        {"transition ease-in duration-150", "opacity-100 translate-y-0 scale-100",
         "opacity-0 -translate-y-1 scale-[0.98]"}
    )
  end

  # A violet check for the active row in a switcher sheet.
  defp check(assigns) do
    ~H"""
    <svg viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5 flex-none text-violet-600 dark:text-violet-400">
      <path
        fill-rule="evenodd"
        d="M16.7 5.3a1 1 0 0 1 0 1.4l-7.5 7.5a1 1 0 0 1-1.4 0l-3.5-3.5a1 1 0 1 1 1.4-1.4l2.8 2.79 6.8-6.79a1 1 0 0 1 1.4 0Z"
        clip-rule="evenodd"
      />
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  defp chevron_down(assigns) do
    ~H"""
    <svg viewBox="0 0 20 20" fill="currentColor" class={@class}>
      <path
        fill-rule="evenodd"
        d="M5.22 8.22a.75.75 0 0 1 1.06 0L10 11.94l3.72-3.72a.75.75 0 1 1 1.06 1.06l-4.25 4.25a.75.75 0 0 1-1.06 0L5.22 9.28a.75.75 0 0 1 0-1.06Z"
        clip-rule="evenodd"
      />
    </svg>
    """
  end
end
