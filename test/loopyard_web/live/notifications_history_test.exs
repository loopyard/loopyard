defmodule LoopyardWeb.NotificationsHistoryTest do
  use LoopyardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "the time machine lists settled questions, newest first", %{conn: conn} do
    Loopyard.StateKeeper.ensure_tables!()
    id = "history-#{System.unique_integer([:positive])}"

    msgs = [
      %{
        id: "hq1",
        role: :question,
        question_id: "hqx",
        status: :answered,
        selections: %{"q1" => ["Yes"]},
        done: ["q1"],
        questions: [
          %{
            id: "q1",
            header: "",
            prompt: "History question?",
            options: [%{label: "Yes", description: nil}]
          }
        ],
        timestamp: DateTime.utc_now()
      }
    ]

    :ets.insert(
      :chat_agents,
      {id, %{id: id, name: "HistoryAgent", status: :idle, messages: msgs}}
    )

    on_exit(fn -> :ets.delete(:chat_agents, id) end)

    {:ok, _view, html} = live(conn, "/notifications/history")

    assert html =~ "Past decisions"
    assert html =~ "History question?"

    # The pending deck does NOT include settled history ("not part of recent").
    {:ok, _view, pending_html} = live(conn, "/notifications")
    refute pending_html =~ "History question?"
  end
end
