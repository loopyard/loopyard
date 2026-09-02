defmodule LoopyardWeb.ReviewDeckTest do
  @moduledoc """
  `/review` is ONE continuously scrollable page of every decision, not one
  decision at a time.

  The one-per-slide Reviewer had a failure you only hit with real questions:
  agents write long ones, a long question is taller than the phone, and the
  Answer/Skip buttons live at its bottom — so the screen showed a wall of text
  with no visible way to act on it, and the only route to the buttons was a
  scroll that the slide UI gave no reason to believe existed.

  Two properties this page has to keep:

    * **Everything is on it.** Otherwise you're back to navigating between
      decisions to find out how many there are.
    * **Answering changes a CARD, never the page.** A settled decision keeps
      its place in the deck instead of vanishing — dropping it would delete a
      section from the middle of a page mid-scroll and slide everything below
      up under the reader's thumb, onto the next decision's buttons.

  A permalink stays a single focused decision. Each card is a mini app you can
  hand someone; the deck is the backlog.
  """
  use LoopyardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  defp pending_question(msg_id, prompt) do
    %{
      id: msg_id,
      role: :question,
      question_id: "qid-#{msg_id}",
      status: :pending,
      selections: %{},
      done: [],
      questions: [
        %{
          id: "q1",
          header: "",
          prompt: prompt,
          options: [%{label: "Yes", description: nil}, %{label: "No", description: nil}]
        }
      ],
      timestamp: DateTime.utc_now()
    }
  end

  defp seed_agent(name, msgs) do
    Loopyard.StateKeeper.ensure_tables!()
    id = "deck-#{System.unique_integer([:positive])}"

    :ets.insert(
      :chat_agents,
      {id, %{id: id, name: name, status: :idle, messages: msgs}}
    )

    on_exit(fn -> :ets.delete(:chat_agents, id) end)
    id
  end

  test "every pending decision is on ONE page", %{conn: conn} do
    seed_agent("Alpha", [pending_question("m-alpha", "First decision?")])
    seed_agent("Beta", [pending_question("m-beta", "Second decision?")])

    {:ok, _view, html} = live(conn, "/decisions")

    assert html =~ "First decision?"

    assert html =~ "Second decision?",
           "the deck exists so you can see the whole backlog without navigating"
  end

  test "each decision is its own snap section", %{conn: conn} do
    seed_agent("Alpha", [pending_question("m-alpha", "First decision?")])
    seed_agent("Beta", [pending_question("m-beta", "Second decision?")])

    {:ok, view, _html} = live(conn, "/decisions")
    html = render(view)

    sections = Regex.scan(~r/<section[^>]*id="decision-[^"]+"/, html)

    assert length(sections) >= 2,
           "each decision needs its own section to snap to; found #{length(sections)}"

    assert html =~ "snap-start",
           "sections snap their TOP to the viewport so you land on a question's first line"
  end

  test "the scroller is marked as a snap deck", %{conn: conn} do
    seed_agent("Alpha", [pending_question("m-alpha", "First decision?")])

    {:ok, _view, html} = live(conn, "/decisions")

    # The snap lives on `html` via `html:has([data-snap-deck])` — the shell is
    # min-h-screen, so the DOCUMENT scrolls and snap set on the inner column
    # would apply to no scroll container at all.
    assert html =~ "data-snap-deck",
           "without this marker the CSS has nothing to key the snap container off"
  end

  test "a permalink is still ONE decision", %{conn: conn} do
    aid = seed_agent("Alpha", [pending_question("m-alpha", "First decision?")])
    seed_agent("Beta", [pending_question("m-beta", "Second decision?")])

    {:ok, _view, html} = live(conn, "/decisions/#{aid}/m-alpha")

    assert html =~ "First decision?"

    refute html =~ "Second decision?",
           "a permalink names one decision — it's a mini app, not the backlog"
  end

  test "answering does not remove the decision from the page", %{conn: conn} do
    aid = seed_agent("Alpha", [pending_question("m-alpha", "First decision?")])
    seed_agent("Beta", [pending_question("m-beta", "Second decision?")])

    {:ok, view, html} = live(conn, "/decisions")
    assert html =~ "First decision?"

    # Settle it the way the real answer path does: the card flips in ETS and a
    # broadcast tells the LiveView.
    [{^aid, summary}] = :ets.lookup(:chat_agents, aid)

    settled =
      Enum.map(summary.messages, fn m ->
        %{m | status: :answered, selections: %{"q1" => ["Yes"]}, done: ["q1"]}
      end)

    :ets.insert(:chat_agents, {aid, %{summary | messages: settled}})

    send(view.pid, %Loopyard.Events.ChatAgentMessage.MessageUpdated{
      agent_id: aid,
      msg: hd(settled)
    })

    html = render(view)

    assert html =~ "First decision?",
           "a settled decision keeps its place — removing it yanks the page mid-scroll"

    assert html =~ "Second decision?", "and the rest of the deck is untouched"
  end
end
