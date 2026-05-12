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
end
