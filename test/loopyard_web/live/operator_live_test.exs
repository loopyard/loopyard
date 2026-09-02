defmodule LoopyardWeb.OperatorLiveTest do
  # async: false — mounts the real operator surface against shared registries.
  use LoopyardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "mounts as ONE chat — no tabs; Decisions is its own root, linked from the bar",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/operator")

    # Decisions used to be a tab under the operator; the row read as two
    # chats. It's a peer now: the mode nav links to /decisions, and nothing on
    # this page is a pane toggle.
    assert has_element?(view, "a[href='/notifications'][aria-label='Notifications']")
    refute html =~ "/operator/decisions"
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
