defmodule BoomLooperWeb.Live.ChatLive.Components.Viewers.TextViewerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  alias BoomLooperWeb.Live.ChatLive.Components.Viewers.TextViewer

  defp render_viewer(content) do
    render_component(&TextViewer.text_viewer/1,
      content: content,
      language: nil,
      path: "test.txt"
    )
  end

  test "renders quotes as proper HTML entities (not double-escaped)" do
    html = render_viewer(~s|gem "rails", "~> 8.0"|)
    # In HTML source, quotes appear as &quot; — that's correct (single escape).
    # Double-escaping would produce &amp;quot; — that's the bug we fixed.
    assert html =~ "&quot;rails&quot;"
    refute html =~ "&amp;quot;", "Double-escaped — raw() isn't working"
  end

  test "escapes HTML tags so they display as text, not execute" do
    html = render_viewer("<script>alert('xss')</script>")
    # The literal <script> tag must NOT appear — it should be escaped
    refute html =~ "<script>alert"
    # The escaped version should be visible as text
    assert html =~ "&lt;script&gt;"
    refute html =~ "&amp;lt;", "Double-escaped — raw() isn't working"
  end

  test "escapes HTML attributes" do
    html = render_viewer(~s|<img src="x" onerror="alert(1)">|)
    refute html =~ "<img src"
    assert html =~ "&lt;img"
  end

  test "renders line numbers" do
    html = render_viewer("line one\nline two\nline three")
    assert html =~ "line one"
    assert html =~ "line three"
    assert html =~ "3 lines"
  end

  test "handles empty content" do
    html = render_viewer("")
    # "" splits to [""] which is 1 line
    assert html =~ "1 lines"
  end
end
