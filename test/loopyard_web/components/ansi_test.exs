defmodule LoopyardWeb.Components.AnsiTest do
  use ExUnit.Case, async: true

  alias LoopyardWeb.Components.Ansi

  describe "to_html/1" do
    test "passes plain text through" do
      assert safe_to_string(Ansi.to_html("hello world")) == "hello world"
    end

    test "converts foreground colors to spans" do
      input = "\e[31mred text\e[0m"
      html = safe_to_string(Ansi.to_html(input))
      assert html =~ ~s(<span class="ansi-red">red text</span>)
    end

    test "handles green" do
      input = "\e[32mgreen\e[0m"
      html = safe_to_string(Ansi.to_html(input))
      assert html =~ ~s(<span class="ansi-green">green</span>)
    end

    test "handles cyan" do
      input = "\e[36mcyan\e[0m"
      html = safe_to_string(Ansi.to_html(input))
      assert html =~ ~s(<span class="ansi-cyan">cyan</span>)
    end

    test "handles bold" do
      input = "\e[1mbold text\e[0m"
      html = safe_to_string(Ansi.to_html(input))
      assert html =~ ~s(<span class="ansi-bold">bold text</span>)
    end

    test "handles bold + color combined" do
      input = "\e[1;31mbold red\e[0m"
      html = safe_to_string(Ansi.to_html(input))
      assert html =~ "ansi-bold"
      assert html =~ "ansi-red"
    end

    test "handles bright colors" do
      input = "\e[91mbright red\e[0m"
      html = safe_to_string(Ansi.to_html(input))
      assert html =~ ~s(ansi-bright-red)
    end

    test "handles multiple color changes" do
      input = "\e[31mred\e[32mgreen\e[0mnormal"
      html = safe_to_string(Ansi.to_html(input))
      assert html =~ "ansi-red"
      assert html =~ "ansi-green"
      assert html =~ "normal"
    end

    test "closes unclosed spans" do
      input = "\e[31mno reset"
      html = safe_to_string(Ansi.to_html(input))
      assert html =~ "<span"
      assert html =~ "</span>"
    end

    test "escapes HTML entities" do
      input = "<script>\e[31malert('xss')\e[0m</script>"
      html = safe_to_string(Ansi.to_html(input))
      assert html =~ "&lt;script&gt;"
      refute html =~ "<script>"
    end

    test "handles empty string" do
      assert safe_to_string(Ansi.to_html("")) == ""
    end

    test "handles Rails-style log output" do
      input = "\e[1m\e[36mStarted GET\e[0m \"/\" \e[1m\e[32mCompleted 200\e[0m"
      html = safe_to_string(Ansi.to_html(input))
      assert html =~ "Started GET"
      assert html =~ "Completed 200"
      refute html =~ "\e["
    end
  end

  describe "strip/1" do
    test "removes all ANSI codes" do
      input = "\e[1m\e[31mhello\e[0m world"
      assert Ansi.strip(input) == "hello world"
    end

    test "handles text without ANSI" do
      assert Ansi.strip("plain text") == "plain text"
    end

    test "handles cursor movement codes" do
      input = "\e[2Jhello\e[H"
      assert Ansi.strip(input) == "hello"
    end
  end

  defp safe_to_string({:safe, iodata}), do: IO.iodata_to_binary(iodata)
  defp safe_to_string(str) when is_binary(str), do: str
end
