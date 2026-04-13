defmodule BoomLooperWeb.Live.ChatLive.Components.Viewers.TextViewerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  alias BoomLooperWeb.Live.ChatLive.Components.Viewers.TextViewer

  defp render_viewer(content, opts \\ []) do
    path = Keyword.get(opts, :path, "test.txt")
    volume = Keyword.get(opts, :volume_name, "bl-test-code")

    render_component(&TextViewer.text_viewer/1,
      content: content,
      path: path,
      volume_name: volume
    )
  end

  test "renders with line numbers" do
    html = render_viewer("line one\nline two\nline three")
    assert html =~ "line one"
    assert html =~ "line three"
    assert html =~ "3 lines"
  end

  test "line numbers are unselectable" do
    html = render_viewer("hello")
    assert html =~ "select-none"
  end

  test "escapes HTML (XSS prevention)" do
    html = render_viewer("<script>alert('xss')</script>")
    refute html =~ "<script>alert"
  end

  test "no double-escaping" do
    html = render_viewer("<b>bold</b>")
    refute html =~ "&amp;lt;", "Double-escaped"
  end

  test "Raw link points to /raw/ endpoint" do
    html = render_viewer("hello", volume_name: "bl-abc-code", path: "Gemfile")
    assert html =~ ~s|href="/raw/bl-abc-code/Gemfile"|
    assert html =~ ~s|target="_blank"|
  end

  test "has .highlight class for Makeup CSS" do
    html = render_viewer("def hello", path: "test.rb")
    assert html =~ "highlight"
  end

  test "highlights Ruby files with spans" do
    html = render_viewer("def hello\n  puts 'world'\nend", path: "test.rb")
    assert html =~ "<span"
  end
end
