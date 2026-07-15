defmodule LoopyardWeb.Components.AppHeader do
  @moduledoc """
  Shared header component used by all LiveViews.
  Shows breadcrumbs, IEx operator indicator, and nav links.
  """
  use Phoenix.Component

  import LoopyardWeb.Components.Breadcrumbs, only: [breadcrumbs: 1]

  @doc """
  Renders the app header bar.

  ## Assigns

    * `:breadcrumbs` — list of `{label, path}` tuples for navigation. Last item is current page (no link).
    * `:iex_session` — current IExSession state (from assign). Optional.
    * `:inner_block` — optional slot for extra header content (buttons, etc.)
  """
  attr :breadcrumbs, :list, default: []
  attr :iex_session, :map, default: %{level: nil}
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
    <LoopyardWeb.Components.Nav.bar height="h-14" gap="gap-3">
      {render_slot(@back)}
      <.breadcrumbs crumbs={@breadcrumbs} />
      <.iex_indicator :if={@iex_session.level} session={@iex_session} />
      <:actions>
        {render_slot(@inner_block)}
        <LoopyardWeb.Components.Common.sound_control id="sound-app" />
        <%!-- Desktop: nav inline. --%>
        <div class="hidden md:flex items-center gap-4">
          <.link
            navigate={Path.join("/remote", @current_path)}
            aria-label={
              if @host_exposed,
                do: "Remote access — exposed. Open connect page.",
                else: "Remote access — private. Open connect page."
            }
            class={[
              "focus-ring inline-flex items-center gap-1.5 px-2 py-1 text-sm font-medium transition-colors rounded",
              if(@host_exposed,
                do: "text-emerald-600 dark:text-emerald-400 hover:text-emerald-500",
                else: "text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-100"
              )
            ]}
          >
            <span
              :if={@host_exposed}
              class="w-1.5 h-1.5 rounded-full bg-emerald-500 flex-none"
              aria-hidden="true"
            ></span>
            Remote
          </.link>
          <%!-- Plain link, not a dropdown — the identity switcher lives on the
               dashboard's Operated card + /workstations. No pop-over menus. --%>
          <.link
            navigate="/workstations"
            class="focus-ring inline-flex items-center gap-1.5 px-2 py-1 text-sm font-medium text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-100 transition-colors rounded"
          >
            <span class="w-1.5 h-1.5 rounded-full bg-sky-500 flex-none" aria-hidden="true"></span>
            {Loopyard.Workstation.current()}
          </.link>
          <.link
            navigate="/system"
            class="focus-ring inline-flex items-center px-2 py-1 text-sm font-medium text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-100 transition-colors rounded"
          >
            System
          </.link>
        </div>
        <%!-- No mobile overflow menu — on a phone, Remote / System / Operated
             live as cards on the home dashboard (tap the breadcrumb home). A
             pop-over menu here was exactly the pattern we're killing. --%>
      </:actions>
    </LoopyardWeb.Components.Nav.bar>
    """
  end

  # Prepend the Loopyard→/ root crumb unless the trail already leads with it
  # (label "Loopyard") or with a link to "/" — so it's safe to call on every page.
  defp with_root([{"Loopyard", _} | _] = crumbs), do: crumbs
  defp with_root([{_, "/"} | _] = crumbs), do: crumbs
  defp with_root(crumbs) when is_list(crumbs), do: [{"Loopyard", "/"} | crumbs]
  defp with_root(_), do: [{"Loopyard", "/"}]

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
    <div class={"flex items-center gap-2 px-3 py-1 rounded-full text-sm #{@bg_color}"}>
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
