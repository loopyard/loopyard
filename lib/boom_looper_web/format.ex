defmodule BoomLooperWeb.Format do
  @moduledoc """
  Display helpers shared across LiveViews and components.

  Anything that's a pure formatting/derivation function and was
  previously copy-pasted into multiple LiveViews lives here. Each
  function is defined ONCE — if you find yourself writing
  `defp shorten_path` anywhere else, delete it and import this module.
  """

  @doc """
  Replace `$HOME` with `~` in a filesystem path. Returns "" for nil/non-string.

      iex> BoomLooperWeb.Format.shorten_path("/Users/me/projects/foo")
      "~/projects/foo"   # if $HOME is /Users/me
  """
  def shorten_path(path) when is_binary(path) do
    home = System.user_home!()
    String.replace_prefix(path, home, "~")
  end
  def shorten_path(_), do: ""

  @doc """
  Human-readable location for a project: shortened path for bind-mount
  projects, git URL for volume-based projects, name as last resort.
  """
  def project_location(project) do
    case {project[:path], project[:git_url]} do
      {path, _} when is_binary(path) -> shorten_path(path)
      {_, url} when is_binary(url) -> url
      _ -> project[:name] || ""
    end
  end

  @doc "Format a byte count as B/KB/MB/GB."
  def format_bytes(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"
  def format_bytes(bytes) when is_integer(bytes) and bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  def format_bytes(bytes) when is_integer(bytes) and bytes < 1_073_741_824, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  def format_bytes(bytes) when is_integer(bytes), do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"
  def format_bytes(bytes) when is_float(bytes), do: format_bytes(round(bytes))
  def format_bytes(_), do: "?"

  @doc "Format an integer with thousand-separator commas."
  def format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
  def format_number(n), do: to_string(n)

  @doc "Format a KB count from `ps aux` as KB or MB."
  def format_rss(kb) when is_integer(kb) and kb < 1024, do: "#{kb} KB"
  def format_rss(kb) when is_integer(kb), do: "#{Float.round(kb / 1024, 1)} MB"
  def format_rss(_), do: "?"

  @doc "Memory usage as a 0-100 percentage."
  def mem_bar_pct(%{total: total, used: used}) when total > 0 do
    Float.round(used / total * 100, 1)
  end
  def mem_bar_pct(_), do: 0

  @doc "Color class for a load average given the number of cores."
  def load_color(load, cores) when load < cores * 0.5, do: "text-green-500"
  def load_color(load, cores) when load < cores * 0.8, do: "text-amber-500"
  def load_color(_, _), do: "text-red-500"

  @doc "Color class for a log level."
  def log_level_class(:error), do: "text-red-500 font-semibold"
  def log_level_class(:warning), do: "text-amber-500"
  def log_level_class(:info), do: "text-blue-400"
  def log_level_class(:debug), do: "text-zinc-500"
  def log_level_class(_), do: "text-zinc-400"
end
