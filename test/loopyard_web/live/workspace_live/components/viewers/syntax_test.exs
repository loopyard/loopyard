defmodule LoopyardWeb.Live.WorkspaceLive.Components.Viewers.SyntaxTest do
  use ExUnit.Case, async: true

  alias LoopyardWeb.Live.WorkspaceLive.Components.Viewers.Syntax

  describe "highlight/2" do
    test "returns raw HTML with span tags for Ruby" do
      result = Syntax.highlight("def hello", "ruby")
      assert {:safe, html} = result
      assert html =~ "<span"
      assert html =~ "hello"
    end

    test "returns raw HTML for Elixir" do
      result = Syntax.highlight("defmodule Foo do", "elixir")
      assert {:safe, html} = result
      assert html =~ "<span"
    end

    test "returns raw HTML for JavaScript" do
      result = Syntax.highlight("const x = 42;", "javascript")
      assert {:safe, html} = result
      assert html =~ "<span"
    end

    test "returns raw HTML for Python" do
      result = Syntax.highlight("def hello():", "python")
      assert {:safe, html} = result
      assert html =~ "<span"
    end

    test "returns plain string for nil language" do
      assert Syntax.highlight("hello", nil) == "hello"
    end

    test "returns nbsp for empty string" do
      assert {:safe, html} = Syntax.highlight("", "ruby")
      assert html =~ "&nbsp;"
    end

    test "doesn't crash on unknown language" do
      result = Syntax.highlight("hello", "nonexistent_lang_xyz")
      # Should return the plain string, not crash
      assert is_binary(result) or match?({:safe, _}, result)
    end

    test "escapes HTML in highlighted output (XSS)" do
      result = Syntax.highlight("<script>alert(1)</script>", "html")

      case result do
        {:safe, html} -> refute html =~ "<script>alert"
        plain when is_binary(plain) -> :ok
      end
    end
  end

  describe "highlight_lines/2 (batch — one tokenize pass)" do
    test "returns one entry per line, aligned to String.split/2" do
      code = "const x = 1;\nfunction f() {\n  return x;\n}"
      lines = Syntax.highlight_lines(code, "javascript")

      assert is_list(lines)
      assert length(lines) == length(String.split(code, "\n"))
    end

    test "each line is highlighted (carries span tags)" do
      lines = Syntax.highlight_lines("def a\ndef b\ndef c", "ruby")
      html = Enum.map_join(lines, "\n", fn {:safe, h} -> h end)
      assert html =~ "<span"
      assert html =~ "def"
    end

    test "preserves line count even with a trailing newline" do
      code = "a = 1\nb = 2\n"
      lines = Syntax.highlight_lines(code, "ruby")
      assert length(lines) == length(String.split(code, "\n"))
    end

    test "keeps the count across a multi-line construct (block comment)" do
      code = "x = 1\n/*\n multi\n line\n*/\ny = 2"
      lines = Syntax.highlight_lines(code, "javascript")
      assert length(lines) == length(String.split(code, "\n"))
    end

    test "blank lines render as &nbsp;, not an empty cell" do
      lines = Syntax.highlight_lines("a = 1\n\nb = 2", "ruby")
      assert {:safe, blank} = Enum.at(lines, 1)
      assert blank =~ "&nbsp;"
    end

    test "returns nil for an unsupported language (caller falls back to plain)" do
      assert Syntax.highlight_lines("whatever\nlines", "nonexistent_lang_xyz") == nil
    end

    test "returns nil for nil language" do
      assert Syntax.highlight_lines("a\nb", nil) == nil
    end
  end
end
