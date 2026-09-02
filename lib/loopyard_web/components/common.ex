defmodule LoopyardWeb.Components.Common do
  @moduledoc """
  Tiny shared components used across LiveViews. Each one replaces a
  block of HTML that was previously copy-pasted into multiple files.

  These are explicitly the **only** components that get auto-imported
  via `LoopyardWeb.html_helpers/0`. Anything page-specific stays in
  its own module.
  """
  use Phoenix.Component

  import LoopyardWeb.Components.AppHeader, only: [header: 1]

  @doc """
  Flash strip — green for `:info`, red for `:error`. Renders nothing if
  the corresponding flash key isn't set.

  <.flash_banner flash={@flash} kind={:info} />
  <.flash_banner flash={@flash} kind={:error} />
  """
  attr :flash, :map, required: true
  attr :kind, :atom, required: true, values: [:info, :error]
  attr :class, :string, default: "mb-4"

  def flash_banner(assigns) do
    # A FLOATING toast, not an in-flow banner: it used to be a full-width <p> that
    # shoved the entire page down when it appeared (jarring, and loud). Now it's
    # fixed-position + compact + centered, so it overlays without shifting layout,
    # and tapping it dismisses (lv:clear-flash). `@class` is ignored for layout —
    # positioning is intrinsic to the toast — but kept for call-site compat.
    ~H"""
    <div
      :if={Phoenix.Flash.get(@flash, @kind)}
      class={[
        "fixed top-3 left-1/2 -translate-x-1/2 z-[60] w-[min(92vw,34rem)] flex items-start gap-2",
        " px-4 py-2.5 text-body shadow-lg shadow-black/10",
        banner_class(@kind)
      ]}
      role="alert"
    >
      <%!-- Text is selectable (select-text) so you can copy the error to paste at
    an agent. ONLY the ✕ dismisses — clicking the body must not clear it out
    from under a copy. --%>
      <span class="flex-1 min-w-0 select-text">{Phoenix.Flash.get(@flash, @kind)}</span>
      <button
        type="button"
        phx-click="lv:clear-flash"
        phx-value-key={@kind}
        aria-label="Dismiss"
        class="flex-none -mr-1 -mt-0.5 px-1 opacity-50 hover:opacity-100 leading-none text-body cursor-pointer"
      >
        &times;
      </button>
    </div>
    """
  end

  defp banner_class(:info) do
    "bg-green-50 dark:bg-green-950/80 border border-green-200 dark:border-green-800/70 text-green-800 dark:text-green-300 backdrop-blur"
  end

  defp banner_class(:error) do
    "bg-red-50 dark:bg-red-950/80 border border-red-200 dark:border-red-800/70 text-red-800 dark:text-red-300 backdrop-blur"
  end

  @doc """
  Loading skeleton. Used as a placeholder while a `start_async` slice is
  in flight. Two shapes:

  <.skeleton />  # one row, generic
  <.skeleton rows={4} />  # multiple stacked rows
  <.skeleton variant={:card} /> # card-shaped (title + bar + small bar)
  """
  attr :rows, :integer, default: 1
  attr :variant, :atom, default: :rows, values: [:rows, :card]
  attr :class, :string, default: ""

  def skeleton(%{variant: :card} = assigns) do
    ~H"""
    <div class={["animate-pulse space-y-2", @class]}>
      <div class="h-6 w-2/3 bg-zinc-200 dark:bg-zinc-700 rounded-sm"></div>
      <div class="h-2 w-full bg-zinc-200 dark:bg-zinc-700 rounded-sm"></div>
      <div class="h-2 w-1/3 bg-zinc-200 dark:bg-zinc-700 rounded-sm"></div>
    </div>
    """
  end

  def skeleton(assigns) do
    ~H"""
    <div class={[
      "rounded-sm border border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50 p-4 space-y-2",
      @class
    ]}>
      <div :for={_ <- 1..@rows} class="h-4 bg-zinc-200 dark:bg-zinc-700 rounded-sm animate-pulse">
      </div>
    </div>
    """
  end

  @doc """
  Detail panel wrapper — the outer flex column that every detail view uses.

  <.detail_panel>
  <:header>Title</:header>
  Content here
  </.detail_panel>
  """
  slot :header, required: true
  slot :inner_block, required: true

  def detail_panel(assigns) do
    ~H"""
    <div class="flex-1 flex flex-col min-h-0">
      <%!-- Desktop-only header. On mobile the section switcher already names the
    selected thing and its details button opens the actions sheet, so this
    bar (name + actions) is redundant chrome — hide it. --%>
      <LoopyardWeb.Components.Nav.bar height="h-12" gap="gap-3" class="hidden md:flex">
        {render_slot(@header)}
      </LoopyardWeb.Components.Nav.bar>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Small control button used in detail view headers.

  <.control_btn>Restart</.control_btn>
  <.control_btn variant={:primary}>+ Debug Agent</.control_btn>
  """
  attr :variant, :atom, default: :default, values: [:default, :primary, :danger]
  # Optional link targets — a toolbar action is often a navigation (Console) or
  # an external link (Open), not a phx-click. Passing any of these renders the
  # SAME-sized control as a link instead of a <button>, so every action in a
  # toolbar is one consistent size.
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :href, :string, default: nil
  # Extra layout classes (e.g. "w-full justify-center" for a stacked sidebar
  # button). Appended AFTER the base + color so callers can stretch/center the
  # control without redefining its look. Kept out of `@rest` so it never
  # produces a duplicate `class` attribute alongside the base.
  attr :class, :string, default: ""

  attr :rest, :global,
    include:
      ~w(phx-click phx-value-id phx-value-service_name phx-value-service phx-value-container_port phx-value-expose phx-value-workspace-id phx-value-volume_name target rel data-confirm)

  slot :inner_block, required: true

  # ONE toolbar-button size + shape everywhere. Only the text color changes by
  # variant. Renders <button> for actions, <.link>/<a> for navigations — same
  # box either way.
  # min-h-11 (44px) is the WCAG/HIG touch-target floor on mobile; md:min-h-8
  # (~32px) keeps the dense desktop toolbar size. So every action button is
  # comfortably tappable on a phone without bloating the desktop rail.
  @control_btn_base "inline-flex items-center min-h-11 md:min-h-8 px-3 py-1.5 rounded-sm text-body font-medium bg-zinc-100 dark:bg-zinc-800 hover:bg-zinc-200 dark:hover:bg-zinc-700 transition-colors"

  def control_btn(assigns) do
    color =
      case assigns.variant do
        :primary ->
          "text-violet-600 dark:text-violet-400"

        # Destructive: red text on a transparent box (set apart from the zinc
        # operational buttons), red-tinted hover. `!` overrides the base zinc
        # bg/hover so a Remove/Delete never looks like a neutral action.
        :danger ->
          "text-red-600 dark:text-red-400 !bg-transparent hover:!bg-red-50 dark:hover:!bg-red-900/20"

        _ ->
          "text-zinc-600 dark:text-zinc-300"
      end

    assigns = assign(assigns, :cls, [@control_btn_base, color, assigns.class])

    ~H"""
    <.link :if={@navigate} navigate={@navigate} class={@cls} {@rest}>
      {render_slot(@inner_block)}
    </.link>
    <.link :if={@patch} patch={@patch} class={@cls} {@rest}>
      {render_slot(@inner_block)}
    </.link>
    <a :if={@href} href={@href} class={@cls} {@rest}>
      {render_slot(@inner_block)}
    </a>
    <button :if={!@navigate && !@patch && !@href} class={@cls} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  Status dot — colored circle for running/stopped/error states.

  <.dot color="bg-emerald-500" />
  <.dot color="bg-red-500" />
  """
  attr :color, :string, required: true

  def dot(assigns) do
    ~H"""
    <div class={"w-2 h-2 rounded-full flex-none #{@color}"}></div>
    """
  end

  @doc """
  THE canonical project·workspace identity — one design-language primitive so a
  "status-light + Project · workspace" reads as *the same thing* everywhere it
  appears: a switcher row, an inline chat mention, a chip, a memo's source line,
  the operator rail. Wherever you name a workspace, use THIS — never hand-roll a
  dot + name again (that drift is exactly what made four different grammars for
  one concept).

  <.workspace_identity project="firehose-site" workspace="main" state={:working} />
  <.workspace_identity project="Loopyard" workspace="cleanup" state={:done} muted />

  `state` is the ONE status vocabulary the light speaks — map your local status
  to it so a color always means the same thing:

  * `:working`  — violet, pulsing (a turn is live)
  * `:needs_you` — flame (blocked on you)
  * `:done`  — emerald (idle / finished)
  * `:asleep`  — zinc (stopped / resting)
  * `:broken`  — red (crashed / errored)

  The workspace renders as a muted "· name" suffix and is ALWAYS shown (the
  identity is project AND workspace); pass `workspace={nil}` only for a
  project-level thing with no workspace.
  """
  attr :project, :string, required: true
  attr :workspace, :string, default: nil
  attr :state, :atom, default: :asleep, values: [:working, :needs_you, :done, :asleep, :broken]
  # Ambient contexts (a nav rail that should recede behind the chat) pass
  # muted={true}: the name dims to a quiet weight so the identity is legible
  # without competing for attention.
  attr :muted, :boolean, default: false
  attr :class, :string, default: nil

  def workspace_identity(assigns) do
    ~H"""
    <%!-- ONE size. It used to take size={:sm|:md}, so the SAME badge rendered at
    13px in the left rail and 16px on the dashboard — the identity of a
    workspace changing size depending on where you met it, which reads as a
    bug because it is one. If a surface needs it quieter, that's `muted`,
    not a different size. --%>
    <span class={["inline-flex items-center gap-2 min-w-0", @class]}>
      <span
        aria-hidden="true"
        class={["flex-none rounded-full w-2 h-2", state_light(@state)]}
      ></span>
      <%!-- No size of its own: it INHERITS the surface it sits on. In a rail
    that's body; inside a turn card, where every font is the chat's reading
    size, it's that. A component that names its own size is the thing that
    makes one card read at two sizes. --%>
      <span class="min-w-0 truncate">
        <span class={
          (@muted && "text-zinc-500 dark:text-zinc-400") ||
            "font-medium text-zinc-800 dark:text-zinc-100"
        }>{@project}</span><span
          :if={@workspace not in [nil, ""]}
          class="text-zinc-400 dark:text-zinc-500"
        > · {@workspace}</span>
      </span>
    </span>
    """
  end

  # The ONE status→light mapping. Every project·workspace light speaks this, so a
  # color always means the same thing across the whole app. (`:chugging` accepted
  # as an alias for the operator rail's live state.)
  @doc """
  A workspace's state as an atom — the ONE derivation.

  Lives here beside `state_light/1` so the dot colour, the status word, and the
  state itself can't drift apart. They already did once: the same agent read
  "Working" in the top bar, "Whirling" in the agent list and "working…" in the
  rail, because each surface had its own vocabulary.
  """
  @working_statuses [:thinking, :compacting, :booting, :backoff, :rate_limited]

  def workspace_state(nil), do: nil

  def workspace_state(ws) do
    cond do
      ws[:needs_you] ->
        :needs_you

      ws[:broken] ->
        :broken

      true ->
        statuses = Enum.map(ws[:agents] || [], &Map.get(&1, :status))

        cond do
          Enum.any?(statuses, &(&1 == :auth_expired)) -> :broken
          Enum.any?(statuses, &(&1 in @working_statuses)) -> :working
          Enum.any?(statuses, &(&1 == :idle)) -> :done
          true -> :asleep
        end
    end
  end

  @doc """
  The state in WORDS. The dot is the fast signal for someone fluent in the
  colours; the word is what makes it legible to everyone else.
  """
  def status_word(:working), do: "Working"
  def status_word(:chugging), do: "Working"
  def status_word(:needs_you), do: "Needs you"
  def status_word(:done), do: "Ready"
  def status_word(:broken), do: "Broken"
  def status_word(_), do: "Asleep"

  @doc "Text colour for `status_word/1`, matching `state_light/1`'s tones."
  def status_class(s) when s in [:working, :chugging],
    do: "text-violet-600 dark:text-violet-400"

  def status_class(:needs_you), do: "text-orange-700 dark:text-orange-400"
  def status_class(:done), do: "text-emerald-600 dark:text-emerald-400"
  def status_class(:broken), do: "text-red-600 dark:text-red-400"
  def status_class(_), do: "text-zinc-400 dark:text-zinc-500"

  @doc """
  Is this state worth SAYING, or does the dot already say it?

  `:done` and `:asleep` are the resting states — the non-event. Printing
  "Ready" beside a green dot spends a word to tell you nothing changed, and
  repeated down a list it's the loudest thing on a calm screen. A state that
  DEPARTS from rest (working, needs you, broken) earns its word.
  """
  def notable_state?(s), do: s not in [nil, :done, :asleep]

  @doc """
  The status word as a styled span. Renders nothing without a state, and
  nothing for a resting one (see `notable_state?/1`) — the dot has it covered.
  """
  attr :state, :atom, default: nil
  attr :class, :string, default: "text-body"

  def status_label(assigns) do
    ~H"""
    <span
      :if={notable_state?(@state)}
      class={["flex-none font-medium", status_class(@state), @class]}
    >
      {status_word(@state)}
    </span>
    """
  end

  def state_light(s) when s in [:working, :chugging], do: "bg-violet-500 animate-pulse"
  def state_light(:needs_you), do: "bg-orange-500"
  def state_light(:done), do: "bg-emerald-500"
  def state_light(:broken), do: "bg-red-500"
  def state_light(_), do: "bg-zinc-400"

  @doc """
  A chevron-right affordance for navigable rows. Scales up slightly on
  desktop. Reacts to a parent `.group` hover.
  """
  def chevron(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 16 16"
      fill="currentColor"
      class="w-4 h-4 md:w-5 md:h-5 flex-none text-zinc-300 dark:text-zinc-600 group-hover:text-zinc-500 dark:group-hover:text-zinc-400 transition-colors"
    >
      <path
        fill-rule="evenodd"
        d="M6.22 4.22a.75.75 0 0 1 1.06 0l3.25 3.25a.75.75 0 0 1 0 1.06l-3.25 3.25a.75.75 0 0 1-1.06-1.06L8.94 8 6.22 5.28a.75.75 0 0 1 0-1.06Z"
        clip-rule="evenodd"
      />
    </svg>
    """
  end

  @doc """
  Responsive grid wrapper for `tile_card`s: one column on mobile, two on
  small screens, three on large. Used by every list page (projects,
  workspaces) so they stay visually consistent.
  """
  slot :inner_block, required: true

  def card_grid(assigns) do
    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3 sm:gap-4">
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  A navigable card tile. On mobile it's a compact row (auto height); on
  desktop it becomes a ~4:3 tile in the `card_grid`, with the content at
  the top and the chevron pinned bottom-right. Responsive-first: one set
  of classes, two shapes.

  Pass `accent` to override the default border/hover (e.g. a running
  workspace gets a green accent).

  <.card_grid>
  <.tile_card :for={p <- @projects} navigate={"/projects/" <> p.id}>
  <h3 class="font-semibold truncate">{p.name}</h3>
  </.tile_card>
  </.card_grid>
  """
  attr :navigate, :string, required: true
  attr :accent, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def tile_card(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "group flex flex-col  border transition-colors p-4 md:p-5 sm:aspect-[4/3]",
        @accent ||
          "border-zinc-200 dark:border-zinc-700 hover:border-violet-400 dark:hover:border-violet-500 hover:bg-zinc-50 dark:hover:bg-zinc-800/50"
      ]}
      {@rest}
    >
      <div class="min-w-0 flex-1">
        {render_slot(@inner_block)}
      </div>
      <div class="mt-3 flex items-center justify-end">
        <.chevron />
      </div>
    </.link>
    """
  end

  @doc """
  A section header: a title (and optional subtitle) on the left, a
  primary action on the right. Stacks vertically on mobile (action goes
  full-width) and becomes a row on desktop. Use the `action` slot for a
  `<.new_button>`.
  """
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :class, :string, default: nil
  slot :action

  def section_header(assigns) do
    ~H"""
    <div class={[
      "flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between mb-4 md:mb-5",
      @class
    ]}>
      <div class="min-w-0">
        <h2 class="text-lead font-semibold">{@title}</h2>
        <p :if={@subtitle} class="text-body text-zinc-500 dark:text-zinc-400 mt-0.5">{@subtitle}</p>
      </div>
      <div :if={@action != []} class="flex-none">
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  @doc """
  The standard primary "New …" action used in a `section_header`.
  Full-width on mobile, auto-width on desktop — consistent everywhere.
  """
  attr :navigate, :string, required: true
  attr :rest, :global
  slot :inner_block, required: true

  def new_button(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="focus-ring inline-flex items-center justify-center gap-1.5 w-full sm:w-auto rounded-sm bg-violet-600 hover:bg-violet-700 text-white px-4 py-2.5 text-body font-semibold transition-colors"
      {@rest}
    >
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4">
        <path d="M10.75 4.75a.75.75 0 0 0-1.5 0v4.5h-4.5a.75.75 0 0 0 0 1.5h4.5v4.5a.75.75 0 0 0 1.5 0v-4.5h4.5a.75.75 0 0 0 0-1.5h-4.5v-4.5Z" />
      </svg>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  @doc """
  Standard page shell for all non-chat pages. Provides consistent
  layout: full-height dark/light bg, header, and centered content area.

  <.page_shell breadcrumbs={[{"Loopyard", "/"}]} iex_session={@iex_session}>
  Page content here
  </.page_shell>

  Options:
  * `max_width` — content width: `:sm`, `:md`, `:lg`, `:xl` (default `:lg`)
  """
  attr :breadcrumbs, :list, required: true
  attr :iex_session, :map, required: true
  attr :max_width, :atom, default: :lg, values: [:sm, :md, :lg, :xl]
  attr :flash, :map, default: %{}
  attr :mode, :atom, default: nil
  slot :header_actions
  slot :inner_block, required: true

  def page_shell(assigns) do
    width_class =
      case assigns.max_width do
        :sm -> "max-w-xl"
        :md -> "max-w-2xl"
        :lg -> "max-w-5xl"
        :xl -> "max-w-6xl"
      end

    assigns = assign(assigns, :width_class, width_class)

    ~H"""
    <div class="min-h-screen bg-brand-paper dark:bg-brand-ink text-zinc-900 dark:text-zinc-100 safe-area-x safe-area-top">
      <.header
        breadcrumbs={@breadcrumbs}
        iex_session={@iex_session}
        mode={@mode}
        host_exposed={Loopyard.Bind.exposed?()}
      >
        {render_slot(@header_actions)}
      </.header>
      <.flash_banner flash={@flash} kind={:error} class="mx-4 mt-2" />
      <.flash_banner flash={@flash} kind={:info} class="mx-4 mt-2" />
      <div class={"#{@width_class} mx-auto px-4 md:px-6 py-6"}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  The MODE NAV — ONE control, per plans/ia-two-modes.md.

  The Operator sits ABOVE the workspaces, so this is a move in altitude, not a
  choice between peers: it always points AWAY from where you are — up to the
  Operator (the trefoil; the operator is loopyard's mind, the brand mark is its
  face) from anywhere else, down to the workspaces (2×2 grid) from the Operator.
  There is no "current" state to style, because it never represents where you
  already are.

  System is deliberately absent: it's a destination you visit on purpose, not a
  mode you toggle, and it lives on the home dashboard.

  Pass a UNIQUE `id` per placement to get the ambient-state indicator (the
  operator link tints while its bed is playing). Two placements on one page
  (the desktop bar and the phone header) need two ids.
  """
  attr :active, :atom, default: nil, values: [nil, :workspaces, :operator, :system]
  attr :id, :string, default: nil
  attr :class, :string, default: nil

  def mode_nav(assigns) do
    ~H"""
    <nav class={["flex items-center", @class]} aria-label="Mode">
      <%!-- The soundtrack rides next to the altitude control in EVERY bar —
      play/pause (and on desktop the track + volume) reachable from
      anywhere, so the bed is the app's soundtrack, not a page you visit.
      Keyed off the placement id like the ambient indicator below. --%>
      <LoopyardWeb.Components.Sound.pill :if={@id} id={@id <> "-sound"} class="mr-1" />
      <%!-- ONE control, not a row of peers. The operator sits ABOVE the
    workspaces — it's where you go to see everything at once — so the move
    is vertical: UP to the operator from a workspace, DOWN into the work
    from the operator. A flat row of three icons said these were siblings,
    which is not how the product is organised.

    System came out of here entirely: it's a destination you visit
    deliberately, not a mode you toggle between, and a gear one tap from
    every screen invites the poking-around that a settings page shouldn't
    get. It lives on the home dashboard, which the brand crumb always
    reaches. --%>
      <%!-- The operator is also the AMBIENT presence, so this link doubles as
    the "is the bed playing" indicator (SoundIcon mirrors engine state onto
    the two data-sound-icon elements). That used to be a separate
    `operator_link/1` with its own icon — which drifted to the command GRID,
    so on a phone the control that goes UP to the operator wore the mark of
    the thing you were already looking at. One control, one mark. --%>
      <.link
        :if={@active != :operator}
        navigate="/operator"
        id={@id}
        phx-hook={@id && "SoundIcon"}
        aria-label="Up to the Operator"
        title="Operator — above the workspaces; run and watch everything"
        class={mode_btn(false)}
      >
        <span data-sound-icon="off"><Brand.mark class="w-5 h-5" /></span>
        <span data-sound-icon="on" class="hidden text-violet-500 dark:text-violet-400">
          <Brand.mark class="w-5 h-5" />
        </span>
      </.link>
      <.link
        :if={@active == :operator}
        navigate="/workspaces"
        aria-label="Down to the workspaces"
        title="Workspaces — drop back into the work"
        class={mode_btn(false)}
      >
        <svg viewBox="0 0 20 20" fill="currentColor" class="w-5 h-5" aria-hidden="true">
          <path d="M3 3.5A1.5 1.5 0 0 1 4.5 2h3A1.5 1.5 0 0 1 9 3.5v3A1.5 1.5 0 0 1 7.5 8h-3A1.5 1.5 0 0 1 3 6.5v-3ZM3 13.5A1.5 1.5 0 0 1 4.5 12h3A1.5 1.5 0 0 1 9 13.5v3A1.5 1.5 0 0 1 7.5 18h-3A1.5 1.5 0 0 1 3 16.5v-3ZM11 3.5A1.5 1.5 0 0 1 12.5 2h3A1.5 1.5 0 0 1 17 3.5v3A1.5 1.5 0 0 1 15.5 8h-3A1.5 1.5 0 0 1 11 6.5v-3ZM11 13.5a1.5 1.5 0 0 1 1.5-1.5h3a1.5 1.5 0 0 1 1.5 1.5v3a1.5 1.5 0 0 1-1.5 1.5h-3a1.5 1.5 0 0 1-1.5-1.5v-3Z" />
        </svg>
      </.link>
    </nav>
    """
  end

  defp mode_btn(_),
    do:
      "flex-none inline-flex items-center justify-center w-11 h-11 md:w-9 md:h-9 rounded-sm text-zinc-500 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800 hover:text-violet-600 dark:hover:text-violet-400 transition-colors"
end
