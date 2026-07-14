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
    ~H"""
    <p :if={Phoenix.Flash.get(@flash, @kind)} class={[@class, banner_class(@kind)]}>
      {Phoenix.Flash.get(@flash, @kind)}
    </p>
    """
  end

  defp banner_class(:info) do
    "rounded-lg bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 px-4 py-3 text-sm text-green-700 dark:text-green-300"
  end

  defp banner_class(:error) do
    "rounded-lg bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 px-4 py-3 text-sm text-red-700 dark:text-red-300"
  end

  @doc """
  Loading skeleton. Used as a placeholder while a `start_async` slice is
  in flight. Two shapes:

      <.skeleton />               # one row, generic
      <.skeleton rows={4} />      # multiple stacked rows
      <.skeleton variant={:card} /> # card-shaped (title + bar + small bar)
  """
  attr :rows, :integer, default: 1
  attr :variant, :atom, default: :rows, values: [:rows, :card]
  attr :class, :string, default: ""

  def skeleton(%{variant: :card} = assigns) do
    ~H"""
    <div class={["animate-pulse space-y-2", @class]}>
      <div class="h-6 w-2/3 bg-zinc-200 dark:bg-zinc-700 rounded"></div>
      <div class="h-2 w-full bg-zinc-200 dark:bg-zinc-700 rounded"></div>
      <div class="h-2 w-1/3 bg-zinc-200 dark:bg-zinc-700 rounded"></div>
    </div>
    """
  end

  def skeleton(assigns) do
    ~H"""
    <div class={[
      "rounded-lg border border-zinc-200 dark:border-zinc-700/80 bg-zinc-50 dark:bg-zinc-800/50 p-4 space-y-2",
      @class
    ]}>
      <div :for={_ <- 1..@rows} class="h-4 bg-zinc-200 dark:bg-zinc-700 rounded animate-pulse"></div>
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
      <div class="flex-none border-b border-zinc-200 dark:border-zinc-700/80 px-4 md:px-5 h-12 flex items-center gap-3">
        {render_slot(@header)}
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Small control button used in detail view headers.

      <.control_btn>Restart</.control_btn>
      <.control_btn variant={:primary}>+ Debug Agent</.control_btn>
  """
  attr :variant, :atom, default: :default, values: [:default, :primary]
  # Optional link targets — a toolbar action is often a navigation (Console) or
  # an external link (Open), not a phx-click. Passing any of these renders the
  # SAME-sized control as a link instead of a <button>, so every action in a
  # toolbar is one consistent size.
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :href, :string, default: nil

  attr :rest, :global,
    include:
      ~w(phx-click phx-value-id phx-value-service_name phx-value-service phx-value-container_port phx-value-expose phx-value-workspace-id phx-value-volume_name target rel data-confirm)

  slot :inner_block, required: true

  # ONE toolbar-button size + shape everywhere. Only the text color changes by
  # variant. Renders <button> for actions, <.link>/<a> for navigations — same
  # box either way.
  @control_btn_base "inline-flex items-center px-3 py-1.5 rounded-md text-sm font-medium bg-zinc-100 dark:bg-zinc-800 hover:bg-zinc-200 dark:hover:bg-zinc-700 transition-colors"

  def control_btn(assigns) do
    color =
      case assigns.variant do
        :primary -> "text-violet-600 dark:text-violet-400"
        _ -> "text-zinc-600 dark:text-zinc-300"
      end

    assigns = assign(assigns, :cls, [@control_btn_base, color])

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
        "group flex flex-col rounded-xl border transition-colors p-4 md:p-5 sm:aspect-[4/3]",
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
        <h2 class="text-lg md:text-xl font-semibold">{@title}</h2>
        <p :if={@subtitle} class="text-sm text-zinc-500 dark:text-zinc-400 mt-0.5">{@subtitle}</p>
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
      class="focus-ring inline-flex items-center justify-center gap-1.5 w-full sm:w-auto rounded-lg bg-violet-600 hover:bg-violet-700 text-white px-4 py-2.5 text-sm font-semibold transition-colors"
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
    <div class="min-h-screen bg-white dark:bg-zinc-900 text-zinc-900 dark:text-zinc-100">
      <.header
        breadcrumbs={@breadcrumbs}
        iex_session={@iex_session}
        host_exposed={Loopyard.HostExposer.exposed?()}
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
  The header ambient-sound control: a scaled-down copy of the /sound play/pause
  button so you can READ the music state at a glance — a play triangle (▶) when
  paused, pause bars (⏸) when playing, pulsing while it connects. It LINKS to the
  full `/sound` page (live nav, so the bed never cuts). The `SoundIcon` JS hook
  mirrors the engine's state onto the icon. Give each placement a unique `id`.
  """
  attr :id, :string, default: "sound-control"
  attr :class, :string, default: nil

  def sound_control(assigns) do
    ~H"""
    <.link
      navigate="/sound"
      id={@id}
      phx-hook="SoundIcon"
      aria-label="Sound"
      class={[
        "flex-none inline-flex items-center justify-center w-11 h-11 rounded-full bg-zinc-100 dark:bg-zinc-800 text-zinc-500 dark:text-zinc-300 hover:bg-zinc-200 dark:hover:bg-zinc-700 transition-colors",
        @class
      ]}
    >
      <%!-- off = play (▶, shown when paused), on = pause (⏸, shown when playing)
           — same icons as the big /sound button, just smaller. --%>
      <svg
        data-sound-icon="off"
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 20 20"
        fill="currentColor"
        class="w-4 h-4 translate-x-px"
      >
        <path d="M6.3 2.841A1.5 1.5 0 0 0 4 4.11v11.78a1.5 1.5 0 0 0 2.3 1.269l9.344-5.89a1.5 1.5 0 0 0 0-2.538L6.3 2.84Z" />
      </svg>
      <svg
        data-sound-icon="on"
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 20 20"
        fill="currentColor"
        class="w-4 h-4 hidden"
      >
        <path d="M5.75 3a.75.75 0 0 0-.75.75v12.5c0 .414.336.75.75.75h1.5a.75.75 0 0 0 .75-.75V3.75A.75.75 0 0 0 7.25 3h-1.5ZM12.75 3a.75.75 0 0 0-.75.75v12.5c0 .414.336.75.75.75h1.5a.75.75 0 0 0 .75-.75V3.75a.75.75 0 0 0-.75-.75h-1.5Z" />
      </svg>
    </.link>
    """
  end
end
