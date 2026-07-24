defmodule Loopyard.Markdown.Stream do
  @moduledoc """
  Incremental Markdown → HTML for LIVE streaming.

  The problem: an agent reply streams token by token, but Markdown is only
  renderable at BLOCK boundaries. Render a half-written `**bold` or an unclosed
  ```` ``` ```` fence and you get garbage; re-render the whole growing reply every
  token and you thrash the DOM (and fight LiveView's diff). Both failure modes
  are exactly what kept breaking.

  The fix: buffer the raw stream on the SERVER and emit only **complete blocks,
  already rendered to safe HTML** (through `Loopyard.Markdown`, so the same MDEx
  escaping boundary holds). The trailing, not-yet-complete block stays a plain
  "tail" the client shows verbatim until it closes. Emitted HTML blocks are
  append-only — the client appends each once and never re-diffs it.

  A block boundary is a blank line (`\\n\\n`) that is NOT inside an open code
  fence, so a fenced code block — blank lines and all — is only emitted once its
  closing fence arrives.

  Per viewer / LiveView connection:

      state = Stream.new()
      {state, html, tail} = Stream.feed(state, delta)  # html: blocks that just closed ("" if none)
      ...
      {html, tail} = Stream.finalize(state)            # flush the last block at end of turn

  The finalized full message re-renders through the SAME renderer, so the
  streamed HTML and the final HTML match — no snap.

  Known limit (self-correcting): a "loose" list whose items are separated by
  blank lines can stream as separate `<ul>`s and coalesce on finalize. Every
  emitted chunk is still valid HTML; only the grouping differs, and the final
  render is correct. Covered by tests so the behavior is intentional, not a
  surprise.
  """

  alias Loopyard.Markdown

  @type t :: %__MODULE__{pending: binary()}
  defstruct pending: ""

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feed a raw delta. Returns `{state, html, tail}`:

    * `html` — safe HTML for any block(s) that completed with this delta (`""`
      if none). Append it; never re-diff it.
    * `tail` — the current incomplete block as PLAIN text. Replace the tail
      element with it (shows the in-progress block verbatim until it closes).
  """
  @spec feed(t(), binary()) :: {t(), binary(), binary()}
  def feed(%__MODULE__{pending: pending} = state, delta) when is_binary(delta) do
    text = pending <> delta

    case split_stable(text) do
      {"", tail} -> {%{state | pending: tail}, "", tail}
      {stable, tail} -> {%{state | pending: tail}, render(stable), tail}
    end
  end

  @doc """
  Flush whatever remains at end of turn. Returns `{html, ""}` — the final
  block(s) rendered, and an empty tail.
  """
  @spec finalize(t()) :: {binary(), binary()}
  def finalize(%__MODULE__{pending: pending}) do
    if String.trim(pending) == "", do: {"", ""}, else: {render(pending), ""}
  end

  # --- internals ---

  # {complete_blocks, incomplete_tail}, split at the last blank line that isn't
  # inside an open code fence.
  defp split_stable(text) do
    case last_boundary(text) do
      0 -> {"", text}
      idx -> {binary_part(text, 0, idx), binary_part(text, idx, byte_size(text) - idx)}
    end
  end

  # Byte index just past the last "\n\n" whose preceding text has all code
  # fences closed (an even number of fence lines). 0 = no safe boundary yet.
  defp last_boundary(text) do
    :binary.matches(text, "\n\n")
    |> Enum.map(fn {pos, len} -> pos + len end)
    |> Enum.reverse()
    |> Enum.find(0, fn b -> fences_closed?(binary_part(text, 0, b)) end)
  end

  defp fences_closed?(chunk) do
    chunk
    |> String.split("\n")
    |> Enum.count(&fence_line?/1)
    |> rem(2) == 0
  end

  defp fence_line?(line), do: line |> String.trim_leading() |> String.starts_with?("```")

  defp render(md), do: md |> Markdown.to_html() |> Phoenix.HTML.safe_to_string()
end
