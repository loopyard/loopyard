defmodule Loopyard.Markdown.StreamTest do
  use ExUnit.Case, async: true

  alias Loopyard.Markdown.Stream

  # Drive a list of deltas through the stream, collecting every emitted HTML
  # chunk and the final tail. Returns {joined_html, final_tail_after_finalize}.
  defp run(deltas) do
    {state, htmls} =
      Enum.reduce(deltas, {Stream.new(), []}, fn delta, {st, acc} ->
        {st, html, _tail} = Stream.feed(st, delta)
        {st, if(html == "", do: acc, else: [html | acc])}
      end)

    {final_html, tail} = Stream.finalize(state)
    htmls = Enum.reverse(if final_html == "", do: htmls, else: [final_html | htmls])
    {Enum.join(htmls, ""), tail}
  end

  describe "block emission" do
    test "a complete paragraph emits a rendered <p>, tail empties" do
      {st, html, tail} = Stream.feed(Stream.new(), "Hello world.\n\n")
      assert html =~ "<p>Hello world.</p>"
      assert tail == ""
      assert st.pending == ""
    end

    test "an incomplete paragraph emits nothing and stays in the tail" do
      {st, html, tail} = Stream.feed(Stream.new(), "Hello wor")
      assert html == ""
      assert tail == "Hello wor"
      assert st.pending == "Hello wor"
    end

    test "a paragraph split across deltas emits once, when it closes" do
      {st, html1, tail1} = Stream.feed(Stream.new(), "Hello ")
      assert html1 == ""
      assert tail1 == "Hello "

      {st, html2, _} = Stream.feed(st, "world.")
      assert html2 == ""

      {_st, html3, tail3} = Stream.feed(st, "\n\n")
      assert html3 =~ "<p>Hello world.</p>"
      assert tail3 == ""
    end

    test "multiple blocks completing in one delta render together" do
      {_st, html, tail} = Stream.feed(Stream.new(), "# Title\n\nA paragraph.\n\n")
      assert html =~ "<h1>"
      assert html =~ "Title"
      assert html =~ "<p>A paragraph.</p>"
      assert tail == ""
    end
  end

  describe "inline markdown never streams half-rendered" do
    test "bold split mid-token stays plain in the tail, renders whole on close" do
      {st, html1, tail1} = Stream.feed(Stream.new(), "**Security")
      assert html1 == ""
      # the tail is the RAW text — we never emit an unclosed <strong>
      assert tail1 == "**Security"

      {_st, html2, _} = Stream.feed(st, " note:**\n\n")
      assert html2 =~ "<strong>Security note:</strong>"
      refute html2 =~ "**"
    end
  end

  describe "code fences" do
    test "a blank line INSIDE an open fence is not a boundary" do
      {st, html, _tail} = Stream.feed(Stream.new(), "```ruby\nx = 1\n\ny = 2\n")
      # fence still open — nothing may be emitted yet
      assert html == ""
      assert st.pending =~ "x = 1"
    end

    test "the fenced block emits whole, only once the closing fence arrives" do
      st = Stream.new()
      {st, h1, _} = Stream.feed(st, "```ruby\n")
      {st, h2, _} = Stream.feed(st, "puts 1\n\nputs 2\n")
      assert h1 == "" and h2 == ""

      {_st, h3, tail} = Stream.feed(st, "```\n\n")
      assert h3 =~ "<code"
      assert h3 =~ "puts 1"
      assert h3 =~ "puts 2"
      assert tail == ""
    end

    test "text before a fence stays buffered with the fence until it closes" do
      # the blank line before the fence IS a valid boundary (fences balanced there)
      {_st, html, _tail} = Stream.feed(Stream.new(), "Intro.\n\n```\ncode\n```\n\n")
      assert html =~ "<p>Intro.</p>"
      assert html =~ "code"
    end
  end

  describe "finalize" do
    test "flushes a trailing block with no closing blank line" do
      st = Stream.new()
      {st, html, tail} = Stream.feed(st, "No trailing newline here")
      assert html == ""
      assert tail == "No trailing newline here"

      {final, tail2} = Stream.finalize(st)
      assert final =~ "<p>No trailing newline here</p>"
      assert tail2 == ""
    end

    test "whitespace-only pending flushes to nothing" do
      {st, _, _} = Stream.feed(Stream.new(), "\n\n  \n")
      assert Stream.finalize(st) == {"", ""}
    end

    test "finalize on a fresh stream is empty" do
      assert Stream.finalize(Stream.new()) == {"", ""}
    end
  end

  describe "end-to-end token-by-token" do
    test "a realistic multi-block reply reconstructs to the full rendered HTML" do
      src = "# Report\n\nFound **two** issues.\n\n```\nline1\nline2\n```\n\nDone.\n\n"
      # feed one char at a time — the worst case for boundary detection
      deltas = for <<c <- src>>, do: <<c>>
      {html, tail} = run(deltas)

      assert tail == ""
      assert html =~ "<h1>"
      assert html =~ "Report"
      assert html =~ "<strong>two</strong>"
      assert html =~ "line1"
      assert html =~ "line2"
      assert html =~ "<p>Done.</p>"
      # never leaked raw markdown syntax
      refute html =~ "**"
    end

    test "no data is lost: every block appears exactly once" do
      deltas = ["First para.\n\n", "Second para.\n\n", "Third para.\n\n"]
      {html, _} = run(deltas)
      assert length(String.split(html, "First para.")) == 2
      assert length(String.split(html, "Second para.")) == 2
      assert length(String.split(html, "Third para.")) == 2
    end
  end
end
