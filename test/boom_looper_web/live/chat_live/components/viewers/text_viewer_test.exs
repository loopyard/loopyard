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

  test "line numbers are unselectable (select-none CSS class)" do
    html = render_viewer("hello")
    assert html =~ "select-none"
  end

  test "escapes HTML tags (XSS prevention)" do
    html = render_viewer("<script>alert('xss')</script>")
    refute html =~ "<script>alert"
    assert html =~ "&lt;script&gt;"
  end

  test "no double-escaping" do
    html = render_viewer("<b>bold</b>")
    refute html =~ "&amp;lt;", "Double-escaped — raw() isn't working"
  end

  test "Raw link points to /raw/ controller endpoint" do
    html = render_viewer("hello", volume_name: "bl-abc-code", path: "Gemfile")
    assert html =~ ~s|href="/raw/bl-abc-code/Gemfile"|
    assert html =~ ~s|target="_blank"|
  end

  test "highlights Ruby files" do
    html = render_viewer("def hello\n  puts 'world'\nend", path: "test.rb")
    assert html =~ "ruby"
    assert html =~ "<span"
  end

  test "highlights Elixir files" do
    html = render_viewer("defmodule Foo do\n  def bar, do: :ok\nend", path: "test.ex")
    assert html =~ "elixir"
    assert html =~ "<span"
  end
end
