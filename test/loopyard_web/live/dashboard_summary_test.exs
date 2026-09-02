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

  setup_all do
    {:ok, _lv, html} = live(build_conn(), "/")
    %{html: html}
  end

  describe "the waiting gauge" do
    test "names what is waiting instead of counting anonymous somethings", %{html: html} do
      # Whatever the number is, "N waiting on you" alone is the failure mode.
      # The noun is DECISION — never the card mechanics ("questions",
      # "approvals"): a question may be an agent telling you something and
      # needing a call on it, and that's a decision too.
      refute html =~ ~r/>\s*\d+ waiting on you\s*</
      refute html =~ ~r/\d+ (questions?|approvals?|secrets?) waiting on you/

      if html =~ ~r/\d+ decisions? waiting on you/ do
        assert html =~ ~s|href="/decisions"|
      end
    end

    test "status reads below the title, not as a corner badge", %{html: html} do
      # The gauge is a LINK — a status you can't act on is decoration. The old
      # badges were bare <span>s floated with ml-auto inside the heading row,
      # so the test that matters is: the health word lives INSIDE the link.
      assert html =~ ~r{<a[^>]+href="/system"[^>]*>.*?(healthy|degraded|down|not ready)}s
      assert html =~ ~s|href="/decisions"|
    end
  end

  describe "recent activity" do
    test "never renders the contentless 'finished a turn' placeholder", %{html: html} do
      # True of every entry ever recorded, therefore worth nothing as a row.
      refute html =~ "finished a turn"
    end
  end
end
