defmodule Loopyard.Markdown do
  @moduledoc """
  Server-side Markdown → safe HTML for chat bubbles.

  Rendering on the SERVER (vs. the old client-side `marked.js` hook) means:

    * the HTML arrives complete — no flash of empty bubbles while the page waits
      for JS to load and the socket to connect,
    * raw HTML embedded in agent/tool output is ESCAPED, not executed — closing
      a client-side XSS hole (`marked` ran unsanitized),
    * the page is smaller — the raw Markdown isn't duplicated into a `data-source`
      attribute on every bubble.

  The raw Markdown is still available per message, on demand, via the
  `/messages/:agent_id/:msg_id/raw` endpoint (the bubble's copy/open buttons) —
  so "render rich, fetch raw when asked" holds.
  """

  # GFM-ish: tables, strikethrough, autolinks, task lists. `unsafe_: false` (the
  # default) escapes raw HTML — this is the security boundary, do not flip it.
  @opts [
    extension: [strikethrough: true, table: true, autolink: true, tasklist: true],
    render: [hardbreaks: true, unsafe_: false]
  ]

  @doc """
  Render Markdown to a Phoenix-safe HTML tuple. Blank/nil → empty. On any
  parser error, falls back to the HTML-escaped raw text (never raises, never
  emits unescaped input).
  """
  @spec to_html(binary() | nil) :: Phoenix.HTML.safe()
  def to_html(content) when content in [nil, ""], do: Phoenix.HTML.raw("")

  def to_html(content) when is_binary(content) do
    # Memoize: content is immutable, and LiveView re-renders every visible
    # bubble on every chat update (hundreds of times per streaming turn). Without
    # the cache, that's MDEx-per-bubble-per-render — enough to starve the LV and
    # time out user sends. A hit is always correct; the table may not exist in a
    # non-app context (raw script), so guard the lookup.
    case cache_get(content) do
      {:ok, safe} -> safe
      :miss -> content |> render!() |> cache_put(content)
    end
  end

  def to_html(_), do: Phoenix.HTML.raw("")

  defp render!(content) do
    case MDEx.to_html(content, @opts) do
      {:ok, html} -> Phoenix.HTML.raw(open_links_in_new_tab(html))
      {:error, _} -> Phoenix.HTML.html_escape(content)
    end
  rescue
    # MDEx is a native dependency — if a still-running server hasn't loaded it
    # yet (added since boot), degrade to escaped text instead of crashing the
    # whole render. A restart picks up the engine and the rich render returns.
    _ -> Phoenix.HTML.html_escape(content)
  end

  defp cache_get(content) do
    case :ets.lookup(:markdown_cache, content) do
      [{^content, safe}] -> {:ok, safe}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_put(safe, content) do
    :ets.insert(:markdown_cache, {content, safe})
    safe
  rescue
    ArgumentError -> safe
  end

  # All links open in a new tab so following one never navigates away from the
  # app. Safe to string-rewrite: MDEx has already sanitized the HTML.
  defp open_links_in_new_tab(html) do
    String.replace(html, "<a href=", ~s(<a target="_blank" rel="noopener noreferrer" href=))
  end
end
