defmodule LoopyardWeb.Live.WorkspaceLive.TranscriptLayoutTest do
  @moduledoc """
  The agent renders as a continuous transcript (document + icon gutter), NOT
  bubbles: prose flows on the surface, the "Claude" identity shows once per run,
  and a faint left spine ties the run together. Humans stay bubbles.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias LoopyardWeb.Live.WorkspaceLive.Messages

  defp render(messages, idx) do
    render_component(&Messages.chat_msg/1, %{
      msg: Enum.at(messages, idx),
      idx: idx,
      messages: messages,
      agent_id: "a1",
      workspace_id: "w1",
      host: "localhost",
      detail_level: :trace
    })
  end

  defp user(text), do: %{role: :user, content: text}
  defp assistant(text), do: %{role: :assistant, content: text, timestamp: ~U[2026-06-21 09:30:00Z]}

  test "agent prose is a document, not a bubble" do
    html = render([user("go"), assistant("On it.")], 1)

    # No chat-bubble chrome on the agent's prose — it's flowing document text.
    # (The faint spine lives on the run wrapper in chat_panel, not the message.)
    refute html =~ "rounded-2xl"
    refute html =~ "bg-zinc-100 dark:bg-zinc-800"
    assert html =~ "leading-relaxed"
    assert html =~ "On it."
  end

  test "transcript_groups bundles consecutive agent messages into one run" do
    msgs = [
      user("go"),
      assistant("First."),
      %{role: :tool, tool: "x"},
      assistant("Done."),
      user("again"),
      assistant("Sure.")
    ]

    groups = Messages.transcript_groups(msgs)

    assert [
             {:break, {%{role: :user}, 0}},
             {:run, run1},
             {:break, {%{role: :user}, 4}},
             {:run, run2}
           ] = groups

    # The whole agent stretch (prose + tool + prose) is ONE run → one header.
    assert Enum.map(run1, fn {_m, i} -> i end) == [1, 2, 3]
    assert Enum.map(run2, fn {_m, i} -> i end) == [5]
  end

  test "a run that opens with a tool is still its own run (header would still show)" do
    # Regression: the header used to live on the assistant clause, so a run
    # starting with a tool had no header. Grouping fixes that.
    [{:break, _}, {:run, run}] =
      Messages.transcript_groups([user("go"), %{role: :tool, tool: "x"}, assistant("hi")])

    assert Enum.map(run, fn {_m, i} -> i end) == [1, 2]
  end

  test "the human prompt is a full-width sticky purple band, not a bubble" do
    html = render([user("make it pop")], 0)
    assert html =~ "sticky"
    assert html =~ "bg-violet-100"
    # No backdrop-blur on the sticky band: blur on a sticky element inside the
    # flex-col-reverse scroll container is a browser compositing bug that made
    # the prompt vanish. Solid fill instead.
    refute html =~ "backdrop-blur"
    assert html =~ "make it pop"
    # Not the old right-aligned bubble.
    refute html =~ "rounded-2xl"
    refute html =~ "items-end"
  end

  test "a flurry of consecutive human messages folds into ONE section (one You area)" do
    msgs = [user("one"), user("two"), user("three"), assistant("got it")]

    # ONE section — the follow-ups + the response all live in its body, so they
    # render as a single grouped "You" area, not three separate cards.
    assert [%{prompt: {%{role: :user, content: "one"}, 0}, body: body}] =
             Messages.transcript_sections(msgs)

    assert [
             {:break, {%{role: :user, content: "two"}, 1}},
             {:break, {%{role: :user, content: "three"}, 2}},
             {:run, _}
           ] = body
  end

  test "the You label + sticky show only on the FIRST of a consecutive run" do
    msgs = [user("first"), user("second")]
    # First: labelled + sticky header for the group.
    first = render(msgs, 0)
    assert first =~ "sticky"
    assert first =~ "You"
    # Second (prev is also user): no label, not sticky — it joins the same area.
    second = render(msgs, 1)
    refute second =~ "sticky"
    refute second =~ "You"
  end

  test "transcript_sections pairs each prompt with the response it owns" do
    msgs = [
      assistant("greeting"),
      user("a"),
      assistant("answer a"),
      user("b"),
      assistant("answer b")
    ]

    assert [
             %{prompt: nil, body: [{:run, _}]},
             %{prompt: {%{role: :user, content: "a"}, 1}, body: [{:run, _}]},
             %{prompt: {%{role: :user, content: "b"}, 3}, body: [{:run, _}]}
           ] = Messages.transcript_sections(msgs)
  end
end
