defmodule LoopyardWeb.Components.AppHeader do
  @moduledoc """
  Shared header component used by all LiveViews.
  Shows breadcrumbs, IEx operator indicator, and nav links.
  """
  use Phoenix.Component

  import LoopyardWeb.Components.Breadcrumbs, only: [breadcrumbs: 1]
  import LoopyardWeb.Components.Icon

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
    ~H"""
    <header class="flex-none h-14 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center justify-between px-4 md:px-5">
      <div class="flex items-center gap-3 min-w-0">
        {render_slot(@back)}
        <.breadcrumbs crumbs={@breadcrumbs} />
        <.iex_indicator :if={@iex_session.level} session={@iex_session} />
      </div>
      <div class="flex items-center gap-3 md:gap-4">
        {render_slot(@inner_block)}
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
          <.workstation_switcher
            current={Loopyard.Workstation.current()}
            ids={Loopyard.Workstation.list()}
          />
          <.link
            navigate="/system"
            class="focus-ring inline-flex items-center px-2 py-1 text-sm font-medium text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-100 transition-colors rounded"
          >
            System
          </.link>
        </div>
        <%!-- Mobile: one overflow menu so the header never crowds at ~375px. --%>
        <.nav_overflow
          current_path={@current_path}
          host_exposed={@host_exposed}
          current={Loopyard.Workstation.current()}
          ids={Loopyard.Workstation.list()}
        />
      </div>
    </header>
    """
  end

  # Mobile-only "⋯"-style menu collapsing Remote / System / Operate-as so the
  # header stays clean on a phone. Pure <details>/<summary> — no JS hook.
  attr :current_path, :string, required: true
  attr :host_exposed, :boolean, required: true
  attr :current, :string, required: true
  attr :ids, :list, required: true

  defp nav_overflow(assigns) do
    ~H"""
    <details class="relative md:hidden" id="nav-overflow">
      <summary class="list-none cursor-pointer focus-ring inline-flex items-center justify-center w-10 h-10 -mr-1.5 rounded-lg text-zinc-500 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800">
        <.icon name={:menu} class="w-5 h-5" />
      </summary>
      <div class="absolute right-0 mt-1.5 w-56 z-50 rounded-lg border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-900 shadow-lg py-1 text-sm">
        <.link
          navigate={Path.join("/remote", @current_path)}
          class="flex items-center gap-2 px-3 py-2.5 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-700 dark:text-zinc-200"
        >
          <span class={[
            "w-1.5 h-1.5 rounded-full flex-none",
            if(@host_exposed, do: "bg-emerald-500", else: "bg-zinc-300 dark:bg-zinc-600")
          ]}></span>
          Remote
          <span class="text-zinc-400 dark:text-zinc-500 text-xs">
            {if @host_exposed, do: "exposed", else: "private"}
          </span>
        </.link>
        <.link
          navigate="/system"
          class="block px-3 py-2.5 hover:bg-zinc-100 dark:hover:bg-zinc-800 text-zinc-700 dark:text-zinc-200"
        >
          System
        </.link>
        <div class="my-1 border-t border-zinc-100 dark:border-zinc-800"></div>
        <div class="px-3 py-1 text-[11px] uppercase tracking-wide text-zinc-400 dark:text-zinc-500">
          Operate as
        </div>
        <.link
          :for={id <- @ids}
          href={"/workstations/#{id}"}
          class={[
            "flex items-center gap-2 px-3 py-2 hover:bg-zinc-100 dark:hover:bg-zinc-800",
            if(id == @current,
              do: "font-medium text-zinc-900 dark:text-zinc-100",
              else: "text-zinc-600 dark:text-zinc-300"
            )
          ]}
        >
          <span class={[
            "w-1.5 h-1.5 rounded-full flex-none",
            if(id == @current,
              do: "bg-sky-500",
              else: "bg-transparent border border-zinc-300 dark:border-zinc-600"
            )
          ]}></span>
          {id}
        </.link>
      </div>
    </details>
    """
  end

  @doc """
  The primary-nav **identity switcher**. Shows who you're operating as
  (`Loopyard.Workstation.current/0`) and drops down to switch — each row links to
  that workstation's page (`/workstations/:id`). *Visiting* a workstation makes it
  the one you're operating as, so the nav, agents, and URL stay in sync.

  Pure `<details>`/`<summary>` — no JS hook, closes on outside click via the
  invisible backdrop label.
  """
  attr :current, :string, required: true
  attr :ids, :list, required: true

  def workstation_switcher(assigns) do
    ~H"""
    <details class="relative group" id="ws-switcher">
      <summary class="list-none cursor-pointer focus-ring inline-flex items-center gap-1.5 px-2 min-h-11 md:min-h-0 md:py-1 text-sm font-medium text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-100 transition-colors rounded">
        <span class="w-1.5 h-1.5 rounded-full bg-sky-500 flex-none" aria-hidden="true"></span>
        <span class="text-zinc-700 dark:text-zinc-200">{@current}</span>
        <.icon
          name={:chevron_down}
          class="w-3.5 h-3.5 opacity-50 group-open:rotate-180 transition-transform"
        />
      </summary>
      <div class="absolute right-0 mt-1.5 w-52 z-50 rounded-lg border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-900 shadow-lg py-1 text-sm">
        <div class="px-3 py-1 text-[11px] uppercase tracking-wide text-zinc-400 dark:text-zinc-500">
          Operate as
        </div>
        <.link
          :for={id <- @ids}
          href={"/workstations/#{id}"}
          class={[
            "flex items-center gap-2 px-3 py-1.5 hover:bg-zinc-100 dark:hover:bg-zinc-800",
            if(id == @current,
              do: "text-zinc-900 dark:text-zinc-100 font-medium",
              else: "text-zinc-600 dark:text-zinc-300"
            )
          ]}
        >
          <span class={[
            "w-1.5 h-1.5 rounded-full flex-none",
            if(id == @current,
              do: "bg-sky-500",
              else: "bg-transparent border border-zinc-300 dark:border-zinc-600"
            )
          ]}></span>
          {id}
        </.link>
        <div class="my-1 border-t border-zinc-100 dark:border-zinc-800"></div>
        <.link
          href="/workstations"
          class="block px-3 py-1.5 text-zinc-500 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800"
        >
          Manage workstations →
        </.link>
      </div>
    </details>
    """
  end

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
    <div class={"flex items-center gap-2 px-3 py-1 rounded-full text-xs #{@bg_color}"}>
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
