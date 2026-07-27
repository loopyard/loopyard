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

  describe "Claude-token mini-app (auth outage)" do
    test "banner + form render when the fleet credential is dead", %{conn: conn} do
      # Fabricate an auth-expired agent summary — the pure-ETS signal
      # Workstation.claude_auth_broken?/0 reads.
      Loopyard.StateKeeper.ensure_tables!()
      id = "authdead-#{System.unique_integer([:positive])}"

      :ets.insert(
        :chat_agents,
        {id, %{id: id, name: "AuthDead", status: :auth_expired, auth_error: "401", messages: []}}
      )

      on_exit(fn -> :ets.delete(:chat_agents, id) end)

      {:ok, view, _html} = live(conn, "/operator")
      # The signal rides refresh_rail — force one tick.
      send(view.pid, :refresh_rail)
      html = render(view)

      assert html =~ "Claude token expired"
      # Routes to the WORKSTATION SETUP flow (the existing machinery), not a
      # hand-rolled form: the minting curl + the Claude page link.
      assert html =~ "claude/setup.sh"
      assert html =~ "/claude"
      refute html =~ "submit_claude_token"
    end

    test "no banner when the fleet is healthy", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/operator")
      send(view.pid, :refresh_rail)
      refute render(view) =~ "Claude token expired"
    end
  end
end
