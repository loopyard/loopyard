defmodule LoopyardWeb.Components.DiffViewTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias LoopyardWeb.Components.DiffView

  defp render(attrs), do: render_component(&DiffView.diff/1, attrs)

  describe "diff/1" do
    test "renders added and removed lines with +/- prefixes" do
      html =
        render(%{
          old: "line one\nline two\nline three",
          new: "line one\nline TWO\nline three",
          path: "foo.txt"
        })

      # added + removed rows both present
      assert html =~ "line TWO"
      assert html =~ "line two"
      # unchanged context survives
      assert html =~ "line one"
      assert html =~ "line three"
    end

    test "highlights known languages (carries span tags)" do
      html =
        render(%{
          old: "const x = 1;",
          new: "const x = 2;\nconst y = 3;",
          path: "app.js"
        })

      assert html =~ "<span"
      assert html =~ "const"
    end

    test "renders a multi-line edit without dropping or duplicating lines" do
      old = Enum.map_join(1..40, "\n", &"old line #{&1} .")
      new = Enum.map_join(1..40, "\n", &"new line #{&1} .")
      # Plain-text path: no syntax spans, so each line stays a contiguous
      # substring. (Highlighted line-count correctness is covered by the
      # Syntax.highlight_lines/2 tests.)
      html = render(%{old: old, new: new, path: "notes.txt"})

      # every new line appears exactly once (trailing " ." disambiguates
      # "new line 1 ." from "new line 10 .")
      for n <- 1..40 do
        assert html |> String.split("new line #{n} .") |> length() == 2
      end

      # all 40 removed + 40 added lines are present — none dropped or merged
      assert html |> String.split("</tr>") |> length() == 81
    end

    test "falls back to a plain (still-correct) diff for unknown languages" do
      html =
        render(%{
          old: "alpha\nbravo",
          new: "alpha\ncharlie",
          path: "data.unknownext"
        })

      assert html =~ "bravo"
      assert html =~ "charlie"
    end

    test "stubs out diffs past the byte cap instead of rendering them" do
      big = String.duplicate("x", 70 * 1024)
      html = render(%{old: big, new: big <> "y", path: "huge.txt"})

      assert html =~ "Diff too large to render inline"
    end
  end
end
