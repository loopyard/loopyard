defmodule BoomLooperWeb.Components.Common do
  @moduledoc """
  Tiny shared components used across LiveViews. Each one replaces a
  block of HTML that was previously copy-pasted into multiple files.

  These are explicitly the **only** components that get auto-imported
  via `BoomLooperWeb.html_helpers/0`. Anything page-specific stays in
  its own module.
  """
  use Phoenix.Component

  import BoomLooperWeb.Components.AppHeader, only: [header: 1]

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

  attr :rest, :global,
    include:
      ~w(phx-click phx-value-id phx-value-service_name phx-value-workspace-id phx-value-volume_name data-confirm)

  slot :inner_block, required: true

  def control_btn(%{variant: :primary} = assigns) do
    ~H"""
    <button
      class="px-2.5 py-1 rounded-md text-xs font-medium bg-zinc-100 dark:bg-zinc-800 hover:bg-zinc-200 dark:hover:bg-zinc-700 text-violet-600 dark:text-violet-400 transition-colors"
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  def control_btn(assigns) do
    ~H"""
    <button
      class="px-2.5 py-1 rounded-md text-xs font-medium bg-zinc-100 dark:bg-zinc-800 hover:bg-zinc-200 dark:hover:bg-zinc-700 text-zinc-600 dark:text-zinc-300 transition-colors"
      {@rest}
    >
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
  Standard page shell for all non-chat pages. Provides consistent
  layout: full-height dark/light bg, header, and centered content area.

      <.page_shell breadcrumbs={[{"Boom Looper", "/"}]} iex_session={@iex_session}>
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
        host_exposed={BoomLooper.HostExposer.exposed?()}
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
end
