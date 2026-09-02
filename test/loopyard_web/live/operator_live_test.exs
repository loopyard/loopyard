defmodule LoopyardWeb.OperatorLiveTest do
  # async: false — mounts the real operator surface against shared registries.
  use LoopyardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "mounts, and the mobile Decisions tab is a PLACE (/decisions), not a pane toggle",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/operator")

    # The tab used to flip an in-page pane whose state was lost on back —
    # tapping a decision and coming back landed on Chat. A URL can't lose its
    # place, so the tab navigates to the deck.
    assert has_element?(view, "a[href='/decisions']", "Decisions")
    refute html =~ "phx-value-v=\"rail\""
    assert Process.alive?(view.pid)
  end

  test "question events route through ConsentUI without crashing the LV", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/operator")

    # No such question — the shared hook answers with the already-answered
    # flash rather than crashing (dead buttons on stale cards must degrade).
    render_hook(view, "draft_question_option", %{
      "question_id" => "nope",
      "q" => "q1",
      "option" => "X"
    })

    render_hook(view, "answer_question_text", %{
      "question_id" => "nope",
      "q" => "q1",
      "text" => ""
    })

    assert Process.alive?(view.pid)
  end

  test "no auth banner apparatus — the calm chat note owns auth recovery", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/operator")
    send(view.pid, :refresh_rail)
    refute render(view) =~ "Claude token expired"
  end
end
