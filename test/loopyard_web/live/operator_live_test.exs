defmodule LoopyardWeb.OperatorLiveTest do
  # async: false — mounts the real operator surface against shared registries.
  use LoopyardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "mounts and the mobile For-you tab toggles to the rail and back", %{conn: conn} do
    {:ok, view, html} = live(conn, "/operator")

    assert html =~ "For you"

    # Tab taps must never be dead: the event is handled and flips the pane.
    html = view |> element("button[phx-value-v=rail]") |> render_click()
    assert html =~ "For you"

    _html = view |> element("button[phx-value-v=chat]") |> render_click()

    # The LV survived both taps (an unhandled event would have crashed it).
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
end
