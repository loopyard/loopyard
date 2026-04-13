defmodule BoomLooperWeb.Live.ChatLive.Components.Viewers.TextViewerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  alias BoomLooperWeb.Live.ChatLive.Components.Viewers.TextViewer

  defp render_viewer(content, opts \\ []) do
    mode = Keyword.get(opts, :mode, :code)
    path = Keyword.get(opts, :path, "test.txt")

    render_component(&TextViewer.text_viewer/1,
      content: content,
      path: path,
      mode: mode
    )
  end

  describe "code mode" do
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

    test "shows Raw toggle button" do
      html = render_viewer("hello")
      assert html =~ "Raw"
      assert html =~ "set_file_mode"
    end
  end

  describe "raw mode" do
    test "renders plain text without line numbers" do
      html = render_viewer("line one\nline two", mode: :raw)
      assert html =~ "line one"
      refute html =~ "select-none"
    end

    test "renders content in a pre tag" do
      html = render_viewer("hello world", mode: :raw)
      assert html =~ "<pre"
      assert html =~ "hello world"
    end
  end

  describe "syntax highlighting" do
    test "highlights Ruby files" do
      html = render_viewer("def hello\n  puts 'world'\nend", path: "test.rb")
      assert html =~ "ruby"
      # Makeup should add span tags for syntax coloring
      assert html =~ "<span"
    end

    test "highlights Elixir files" do
      html = render_viewer("defmodule Foo do\n  def bar, do: :ok\nend", path: "test.ex")
      assert html =~ "elixir"
      assert html =~ "<span"
    end

    test "plain text files get no highlighting" do
      html = render_viewer("just plain text", path: "readme.txt")
      refute html =~ "<span class=\""
    end
  end
end
