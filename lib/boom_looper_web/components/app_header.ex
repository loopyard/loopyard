defmodule BoomLooperWeb.Components.AppHeader do
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
  attr :current_path, :string, default: "/"
  attr :host_exposed, :boolean, default: false
  slot :inner_block

  def header(assigns) do
    ~H"""
    <header class="flex-none h-14 border-b border-zinc-200 dark:border-zinc-700/80 flex items-center justify-between px-4 md:px-5">
      <div class="flex items-center gap-3 min-w-0">
        <.breadcrumbs crumbs={@breadcrumbs} />
        <.iex_indicator :if={@iex_session.level} session={@iex_session} />
      </div>
      <div class="flex items-center gap-4">
        {render_slot(@inner_block)}
        <.link navigate={"/connect?path=#{URI.encode(@current_path)}"} class={[
          "text-xs transition-colors flex items-center gap-1.5",
          if(@host_exposed,
            do: "text-emerald-600 dark:text-emerald-400 hover:text-emerald-500",
            else: "text-zinc-400 dark:text-zinc-500 hover:text-zinc-600 dark:hover:text-zinc-300")
        ]}>
          <span :if={@host_exposed} class="w-1.5 h-1.5 rounded-full bg-emerald-500 flex-none"></span>
          Remote
        </.link>
        <.link navigate="/system" class="text-xs text-zinc-400 dark:text-zinc-500 hover:text-zinc-600 dark:hover:text-zinc-300 transition-colors">System</.link>
      </div>
    </header>
    """
  end

  defp breadcrumbs(assigns) do
    ~H"""
    <div class="flex items-center gap-2 min-w-0">
      <span :for={{label, path, is_last} <- with_last(@crumbs)}>
        <.link :if={!is_last} navigate={path} class="text-sm font-semibold tracking-tight hover:text-violet-600 dark:hover:text-violet-400 transition-colors">{label}</.link>
        <span :if={is_last} class="text-sm font-medium">{label}</span>
        <span :if={!is_last} class="text-zinc-300 dark:text-zinc-600 ml-2">/</span>
      </span>
    </div>
    """
  end

  defp with_last([]), do: []
  defp with_last(crumbs) do
    last_idx = length(crumbs) - 1
    crumbs
    |> Enum.with_index()
    |> Enum.map(fn {{label, path}, idx} -> {label, path, idx == last_idx} end)
  end

  def iex_indicator(assigns) do
    {dot_color, bg_color} = case assigns.session.level do
      :green -> {"bg-green-400", "bg-green-500/20 text-green-600 dark:text-green-400"}
      :yellow -> {"bg-yellow-400 animate-pulse", "bg-yellow-500/20 text-yellow-600 dark:text-yellow-400"}
      :red -> {"bg-red-500 animate-pulse", "bg-red-500/20 text-red-600 dark:text-red-400"}
      _ -> {"bg-zinc-400", "bg-zinc-500/20 text-zinc-600 dark:text-zinc-400"}
    end

    assigns = assigns
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
