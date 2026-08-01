defmodule LoopyardWeb.Components.AppHeader do
  @moduledoc """
  Shared header component used by all LiveViews.
  Shows breadcrumbs, IEx operator indicator, and nav links.
  """
  use Phoenix.Component

  @doc """
  Renders the app header bar.

  ## Assigns

  * `:breadcrumbs` — list of `{label, path}` tuples for navigation. Last item is current page (no link).
  * `:iex_session` — current IExSession state (from assign). Optional.
  * `:inner_block` — optional slot for extra header content (buttons, etc.)
  """
  attr :breadcrumbs, :list, default: []
  attr :iex_session, :map, default: %{level: nil}
  # Which IA mode this page belongs to (highlights in the mode nav) — see
  # plans/ia-two-modes.md. nil = a page outside the three roots.
  attr :mode, :atom, default: nil
  attr :current_path, :string, default: "/"
  attr :host_exposed, :boolean, default: false
  slot :back, doc: "Optional leading element (e.g. a mobile back button) before the breadcrumbs."
  slot :inner_block

  def header(assigns) do
    # Every top-level screen pops back to root by clicking "Loopyard". Guarantee
    # the trail leads with a clickable Loopyard→/ crumb here, in the one shared
    # header, so no page can forget it (workstations did). Idempotent: pages that
    # already lead with Loopyard (or the root "/") are left as-is — no double crumb.
    assigns = assign(assigns, :breadcrumbs, with_root(assigns.breadcrumbs))

    ~H"""
    <%!-- Insets: the page shell owns them (docs/CODE_RULES.md). --%>
    <%!-- Three zones, the one model (see Breadcrumbs.trail/1): brand + ancestors
         left, the CURRENT thing centred, actions right.
         A GRID, not absolute positioning: `1fr auto 1fr` centres the middle
         against the bar (both side columns take an equal share of free space)
         AND reserves real space for it, so it can never overlap the actions.
         Absolute centring did exactly that on a 390px phone — the title sat on
         top of the mode icons. --%>
    <div class="flex-none grid grid-cols-[auto_1fr_auto] sm:grid-cols-[1fr_auto_1fr] items-center gap-3 h-14 px-4 md:px-5 border-b border-zinc-200 dark:border-zinc-700/80">
      <div class="min-w-0 flex items-center gap-3">
        {render_slot(@back)}
        <LoopyardWeb.Components.Breadcrumbs.trail crumbs={@breadcrumbs} />
      </div>

      <%!-- Centred from sm: up. On a 390px phone there is not room to centre a
           title AND clear three action icons — it collided. Phones get the
           title next to the back button (the mobile spec is "a back button",
           not a centred title); the centred zone returns as soon as there's
           width for it. --%>
      <div class="min-w-0 flex items-center justify-start sm:justify-center">
        <LoopyardWeb.Components.Breadcrumbs.current crumbs={@breadcrumbs} />
      </div>

      <div class="min-w-0 flex items-center justify-end gap-3">
        <.iex_indicator :if={@iex_session.level} session={@iex_session} />
        {render_slot(@inner_block)}
        <%!-- The mode nav (Workspaces ⇄ Operator, System) — the ONE global
             navigation, identical on every shell. --%>
        <LoopyardWeb.Components.Common.mode_nav active={@mode} />
      </div>
    </div>
    """
  end

  @doc """
  Prepend the Loopyard→/ root crumb unless the trail already leads with it
  (label "Loopyard") or with a link to "/" — so it's safe to call on every page.

  Public because FocusedView needs the same guarantee: the root crumb has to
  carry the EXACT label `Breadcrumbs.brand_root?/2` matches on, or it renders as
  plain text and the trefoil silently disappears. Callers should never hand-write
  that crumb — route it through here.
  """
  def with_root([{"Loopyard", _} | _] = crumbs), do: crumbs
  def with_root([{_, "/"} | _] = crumbs), do: crumbs
  def with_root(crumbs) when is_list(crumbs), do: [{"Loopyard", "/"} | crumbs]
  def with_root(_), do: [{"Loopyard", "/"}]

  def iex_indicator(assigns) do
    {dot_color, bg_color} =
      case assigns.session.level do
        :green ->
          {"bg-green-400", "bg-green-500/20 text-green-600 dark:text-green-400"}

        :yellow ->
          {"bg-yellow-400 animate-pulse", "bg-yellow-500/20 text-yellow-600 dark:text-yellow-400"}

        :red ->
          {"bg-red-500 animate-pulse", "bg-red-500/20 text-red-600 dark:text-red-400"}

        _ ->
          {"bg-zinc-400", "bg-zinc-500/20 text-zinc-600 dark:text-zinc-400"}
      end

    assigns =
      assigns
      |> assign(:dot_color, dot_color)
      |> assign(:bg_color, bg_color)
      |> assign(:time_ago, relative_time(assigns.session.at))

    ~H"""
    <div class={"flex items-center gap-2 px-3 py-1 rounded-full text-body #{@bg_color}"}>
      <span class={"w-2 h-2 rounded-full flex-none #{@dot_color}"}></span>
      <span class="font-medium">IEx</span>
      <span class="opacity-75">{@session.label}</span>
      <span class="opacity-50">{@time_ago}</span>
    </div>
    """
  end

  defp relative_time(nil), do: ""

  defp relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 5 -> "now"
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m"
      true -> "#{div(diff, 3600)}h"
    end
  end
end
