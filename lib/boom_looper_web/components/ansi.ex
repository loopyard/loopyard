defmodule BoomLooperWeb.Components.Ansi do
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
    # The HTML is already escaped, but ANSI codes got escaped too:
    # \x1b became &#x1b; or was preserved. We need to work on the
    # raw bytes. Since Phoenix html_escape doesn't touch \x1b (it's
    # not <, >, &, or "), the escape bytes are still literal \x1b.
    parts = Regex.split(@ansi_pattern, escaped_html, include_captures: true)

    {html, open?} =
      Enum.reduce(parts, {"", false}, fn part, {acc, in_span} ->
        case Regex.run(@ansi_pattern, part) do
          [_, codes_str] ->
            codes = String.split(codes_str, ";", trim: true)
            classes = codes_to_classes(codes)

            close = if in_span, do: "</span>", else: ""

            if classes == "" do
              # Reset — just close
              {acc <> close, false}
            else
              {acc <> close <> "<span class=\"#{classes}\">", true}
            end

          nil ->
            {acc <> part, in_span}
        end
      end)

    if open?, do: html <> "</span>", else: html
  end

  defp codes_to_classes(codes) do
    codes
    |> Enum.map(fn code ->
      cond do
        code == "0" -> nil
        code == "1" -> "ansi-bold"
        code == "2" -> "ansi-dim"
        code == "3" -> "ansi-italic"
        code == "4" -> "ansi-underline"
        Map.has_key?(@colors, code) -> @colors[code]
        true -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end
end
