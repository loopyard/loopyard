defmodule LoopyardWeb.Components.Ansi do
  @moduledoc """
  Convert ANSI escape sequences to HTML spans with color classes.

  Handles the common SGR (Select Graphic Rendition) codes that dev
  servers, Rails, and build tools emit. Unsupported codes are stripped.
  """

  @ansi_pattern ~r/\x1b\[([0-9;]*)m/

  @colors %{
    "30" => "ansi-black",
    "31" => "ansi-red",
    "32" => "ansi-green",
    "33" => "ansi-yellow",
    "34" => "ansi-blue",
    "35" => "ansi-magenta",
    "36" => "ansi-cyan",
    "37" => "ansi-white",
    "90" => "ansi-bright-black",
    "91" => "ansi-bright-red",
    "92" => "ansi-bright-green",
    "93" => "ansi-bright-yellow",
    "94" => "ansi-bright-blue",
    "95" => "ansi-bright-magenta",
    "96" => "ansi-bright-cyan",
    "97" => "ansi-bright-white"
  }

  # The color class names — used to REPLACE (not stack) the color when a new
  # color code arrives, while attributes like bold/underline accumulate.
  @color_classes @colors |> Map.values() |> MapSet.new()

  @doc """
  Convert ANSI-colored text to HTML. Returns a Phoenix.HTML safe string.

  Each color run becomes a `<span class="ansi-COLOR">...</span>`.
  Reset codes (0) close the current span. Bold (1) adds `ansi-bold`.
  """
  def to_html(text) when is_binary(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> convert_ansi()
    |> Phoenix.HTML.raw()
  end

  @doc "Strip all ANSI escape sequences, returning plain text."
  def strip(text) when is_binary(text) do
    Regex.replace(~r/\x1b\[[0-9;]*[a-zA-Z]/, text, "")
  end

  defp convert_ansi(escaped_html) do
    # The HTML is already escaped, but ANSI codes are not (\x1b isn't <, >, &, or
    # "), so the escape bytes are still literal. Split into code sequences and
    # text runs, ACCUMULATING the active SGR state across codes, and wrap each
    # text run in a span carrying the full state. This is what makes `\e[1m\e[36m`
    # (Rails' bold-cyan) render bold AND cyan — folding, not reset-on-each-code —
    # and it emits no empty spans.
    @ansi_pattern
    |> Regex.split(escaped_html, include_captures: true)
    |> Enum.reduce({[], []}, fn part, {acc, active} ->
      case Regex.run(@ansi_pattern, part) do
        [_, codes_str] ->
          {acc, apply_codes(active, String.split(codes_str, ";", trim: true))}

        nil ->
          run =
            if part == "" or active == [],
              do: part,
              else: [~s(<span class="), Enum.join(active, " "), ~s(">), part, "</span>"]

          {[acc | run], active}
      end
    end)
    |> elem(0)
    |> IO.iodata_to_binary()
  end

  # Fold SGR codes into the active class list. Reset (0, or an empty `\e[m`)
  # clears everything; a new COLOR replaces any prior color; attributes
  # (bold/dim/italic/underline) accumulate on top.
  defp apply_codes(_active, []), do: []

  defp apply_codes(active, codes) do
    Enum.reduce(codes, active, fn code, acc ->
      cond do
        code == "0" -> []
        code == "1" -> add_once(acc, "ansi-bold")
        code == "2" -> add_once(acc, "ansi-dim")
        code == "3" -> add_once(acc, "ansi-italic")
        code == "4" -> add_once(acc, "ansi-underline")
        Map.has_key?(@colors, code) -> put_color(acc, @colors[code])
        true -> acc
      end
    end)
  end

  defp add_once(list, cls), do: if(cls in list, do: list, else: list ++ [cls])

  defp put_color(list, color),
    do: Enum.reject(list, &MapSet.member?(@color_classes, &1)) ++ [color]
end
