defmodule Loopyard.Markdown.Stream do
  @moduledoc """
  Incremental Markdown → HTML for LIVE streaming.

  The problem: an agent reply streams token by token, but Markdown is only
  renderable at BLOCK boundaries. Render a half-written `**bold` or an unclosed
  ```` ``` ```` fence and you get garbage; re-render the whole growing reply every
  token and you thrash the DOM (and fight LiveView's diff). Both failure modes
  are exactly what kept breaking.

  The fix: buffer the raw stream on the SERVER. Completed blocks are emitted as
  safe HTML (through `Loopyard.Markdown`, so the MDEx escaping boundary holds),
  append-only — the client appends each once and never re-diffs it. The trailing,
  not-yet-complete block is ALSO rendered to HTML (it's small — one block — so
  re-rendering it per delta is cheap) and shipped as the "tail" the client swaps
  in place. MDEx renders balanced inline markup correctly, so `**bold**` inside
  the tail shows bold; only a genuinely UNCLOSED marker briefly renders literally,
  resolving on the next delta. No whole paragraph of raw `**` ever shows.

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
    * `tail` — the current incomplete block rendered to safe HTML (`""` if none).
      Swap the tail element's contents with it each delta.
  """
  @spec feed(t(), binary()) :: {t(), binary(), binary()}
  def feed(%__MODULE__{pending: pending} = state, delta) when is_binary(delta) do
    {stable, tail} = split_stable(pending <> delta)
    {%{state | pending: tail}, render(stable), render(tail)}
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
