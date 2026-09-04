defmodule LoopyardWeb.NotificationsDeckTest do
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

  defp multi_question(msg_id, prompts) do
    %{
      id: msg_id,
      role: :question,
      question_id: "qid-#{msg_id}",
      status: :pending,
      selections: %{},
      done: [],
      questions:
        for {prompt, i} <- Enum.with_index(prompts, 1) do
          %{
            id: "q#{i}",
            header: "",
            prompt: prompt,
            options: [%{label: "Yes", description: nil}, %{label: "No", description: nil}]
          }
        end,
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

    # Cards written straight into ETS never pass the message funnels — this is
    # the restart-replay shape — so sweep, as the store does when an agent
    # resumes.
    Loopyard.Notifications.reconcile()
    Loopyard.Notifications.sync()

    on_exit(fn ->
      :ets.delete(:chat_agents, id)

      for %{agent_id: ^id, id: nid} <- Loopyard.Notifications.all(),
          do: :ets.delete(:notifications, nid)
    end)

    id
  end

  test "a finished turn is a slide with Keep going / Open / Dismiss; dismissing settles it",
       %{conn: conn} do
    aid = seed_agent("Gamma", [])

    Loopyard.Events.Activity.publish(%Loopyard.Events.Activity.Event{
      agent_id: aid,
      agent_name: "Gamma",
      workspace_id: "ws-" <> aid,
      kind: :turn_end,
      summary: "Wired the images in.",
      at: DateTime.utc_now()
    })

    Loopyard.Notifications.sync()
    on_exit(fn -> :ets.delete(:notifications, "fin:" <> aid) end)

    {:ok, view, html} = live(conn, "/notifications")
    assert html =~ "Wired the images in."
    assert html =~ "Keep going"
    assert has_element?(view, "button[phx-click=dismiss_item][phx-value-id='fin:#{aid}']")

    render_click(view, "dismiss_item", %{"id" => "fin:" <> aid})
    Loopyard.Notifications.sync()
    assert %{status: :dismissed} = Loopyard.Notifications.get("fin:" <> aid)
    assert render(view) =~ "Dismissed", "the slide stays, as a receipt"
  end

  test "the count is of what's still WAITING, oldest first", %{conn: conn} do
    old_q = pending_question("m-old", "Asked first?")
    new_q = %{pending_question("m-new", "Asked second?") | timestamp: DateTime.utc_now()}
    old_q = %{old_q | timestamp: DateTime.add(DateTime.utc_now(), -60, :second)}
    seed_agent("Chrono", [old_q, new_q])

    {:ok, view, html} = live(conn, "/notifications")

    # Oldest first: the question asked first is the one you answer first, so
    # the newest is LAST, not "1 of 2".
    {first_at, _} = :binary.match(html, "Asked first?")
    {second_at, _} = :binary.match(html, "Asked second?")
    assert first_at < second_at

    assert html =~ "1 of 2"
    assert html =~ "2 of 2"

    # Settling one takes it out of the COUNT, though its slide stays as a
    # receipt — so the number always says how much is left.
    render_click(view, "skip_question", %{"question_id" => "qid-m-old", "q" => "q1"})
    Loopyard.Notifications.sync()

    html = render(view)
    refute html =~ "2 of 2", "a settled card is no longer one of the things waiting"
  end

  test "one ask fans out in the order it was asked, and answering one renumbers the rest",
       %{conn: conn} do
    seed_agent("Twenty", [multi_question("m-20q", ["First?", "Second?", "Third?"])])

    {:ok, view, html} = live(conn, "/notifications")

    # The agent's order is the reading order: you answer its first question
    # first, not its last.
    {a, _} = :binary.match(html, "First?")
    {b, _} = :binary.match(html, "Second?")
    {c, _} = :binary.match(html, "Third?")
    assert a < b and b < c

    assert html =~ "1 of 3"
    assert html =~ "3 of 3"

    # A question of a multi-question ask resolves ON ITS OWN. The message stays
    # pending until the last one lands, so counting the MESSAGE left two
    # answered questions still claiming to be waiting.
    render_click(view, "skip_question", %{"question_id" => "qid-m-20q", "q" => "q1"})
    Loopyard.Notifications.sync()

    html = render(view)
    refute html =~ "3 of 3", "answering one of three leaves two waiting, not three"
    assert html =~ "First?", "the answered question keeps its place as a receipt"
  end

  test "every pending decision is on ONE page", %{conn: conn} do
    seed_agent("Alpha", [pending_question("m-alpha", "First decision?")])
    seed_agent("Beta", [pending_question("m-beta", "Second decision?")])

    {:ok, _view, html} = live(conn, "/notifications")

    assert html =~ "First decision?"

    assert html =~ "Second decision?",
           "the deck exists so you can see the whole backlog without navigating"
  end

  test "each decision is its own slide, snapping into place", %{conn: conn} do
    seed_agent("Alpha", [pending_question("m-alpha", "First decision?")])
    seed_agent("Beta", [pending_question("m-beta", "Second decision?")])

    {:ok, view, _html} = live(conn, "/notifications")
    html = render(view)

    slides = Regex.scan(~r/<section[^>]*id="slide-[^"]+"/, html)

    assert length(slides) >= 2,
           "each decision needs its own slide to swipe to; found #{length(slides)}"

    assert html =~ "snap-start",
           "slides snap their leading edge into place — one decision fills the screen"
  end

  test "the deck is a horizontal scroll-snap carousel, no JS gestures", %{conn: conn} do
    seed_agent("Alpha", [pending_question("m-alpha", "First decision?")])

    {:ok, _view, html} = live(conn, "/notifications")

    # Swipe left/right is the browser's own horizontal scrolling with CSS snap —
    # nothing that competes with the iOS back gesture. The carousel is the
    # scroll container itself (flex + overflow-x), not the document.
    assert html =~ ~r/id="decisions-deck"[^>]*class="[^"]*snap-x[^"]*snap-mandatory/,
           "the deck must be an x-axis snap scroller"
  end

  test "a permalink opens the deck AT that decision", %{conn: conn} do
    aid = seed_agent("Alpha", [pending_question("m-alpha", "First decision?")])
    seed_agent("Beta", [pending_question("m-beta", "Second decision?")])

    {:ok, _view, html} = live(conn, "/notifications/#{aid}/m-alpha")

    # The whole deck is there (swipe onward from the one you were sent to)…
    assert html =~ "First decision?"
    assert html =~ "Second decision?"

    # …and the named slide takes focus on mount, which scrolls the carousel to
    # it natively — no scroll JS.
    assert html =~ ~r/<section[^>]*id="slide-#{aid}-m-alpha-[^"]*"[^>]*phx-mounted=/,
           "the permalinked slide must be the one focused on mount"
  end

  test "answering does not remove the decision from the page", %{conn: conn} do
    aid = seed_agent("Alpha", [pending_question("m-alpha", "First decision?")])
    seed_agent("Beta", [pending_question("m-beta", "Second decision?")])

    {:ok, view, html} = live(conn, "/notifications")
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
