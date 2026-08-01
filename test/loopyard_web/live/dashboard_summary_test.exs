defmodule LoopyardWeb.DashboardSummaryTest do
  @moduledoc """
  A dashboard card has to answer the question it raises.

  The Operator card used to say "6 waiting on you" in the corner and, below it,
  "Claude — finished a turn" five times. Every word of that is true and none of
  it is information: six WHAT, and finished doing what? These tests hold the two
  rules that fixed it — name the nouns, and show the thing itself.
  """
  use LoopyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "the waiting gauge" do
    test "names what is waiting instead of counting anonymous somethings" do
      {:ok, _lv, html} = live(build_conn(), "/")

      # Whatever the number is, "N waiting on you" alone is the failure mode:
      # the reader can't tell a question from an approval from a secret.
      if html =~ ~r/\d+ (questions?|approvals?|secrets?)/ do
        assert html =~ "waiting on you"
      end

      refute html =~ ~r/>\s*\d+ waiting on you\s*</
    end

    test "status reads below the title, not as a corner badge" do
      {:ok, _lv, html} = live(build_conn(), "/")

      # The gauge is a LINK — a status you can't act on is decoration. The old
      # badges were bare <span>s floated with ml-auto inside the heading row.
      refute html =~ ~r/ml-auto[^"]*"[^>]*>\s*(healthy|degraded|down)\s*</
      assert html =~ ~s|href="/system"|
      assert html =~ ~s|href="/review"|
    end
  end

  describe "recent activity" do
    test "never renders the contentless 'finished a turn' placeholder" do
      {:ok, _lv, html} = live(build_conn(), "/")

      # True of every entry ever recorded, therefore worth nothing as a row.
      refute html =~ "finished a turn"
    end
  end
end
