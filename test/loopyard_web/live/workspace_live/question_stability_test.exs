defmodule LoopyardWeb.Live.WorkspaceLive.QuestionStabilityTest do
  @moduledoc """
  ANSWERING A QUESTION CHANGES COLOUR, NOT GEOMETRY.

  Every version of this card has drifted when it settled: an "Answered" header
  row inserted above the question pushed the question down; receipt rows with
  tighter padding than the option rows nudged every line; a full-bleed receipt
  moved the text to a different left edge from the options it replaced. Each
  one is a few pixels, and each one is visible, because it happens under your
  thumb at the moment you tap.

  So the rule is mechanical: the row you tapped keeps its box. These tests
  compare the geometry-bearing classes of the two states rather than trusting
  a screenshot.
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias LoopyardWeb.Live.WorkspaceLive.Messages.Cards.Question

  @geometry ~w(px-3 py-2.5 md:py-2 gap-3 rounded-sm)

  defp question, do: %{id: "q1", header: "", prompt: "Raptor?", options: opts()}

  defp opts,
    do: [
      %{label: "Yes", description: "A predatory raptor"},
      %{label: "No", description: "Not a raptor"}
    ]

  defp msg(extra) do
    Map.merge(
      %{
        id: "m1",
        role: :question,
        question_id: "qid-1",
        status: :pending,
        selections: %{},
        done: [],
        questions: [question()],
        timestamp: DateTime.utc_now()
      },
      extra
    )
  end

  defp render_block(msg) do
    render_component(&Question.question_block/1, %{msg: msg, q: question(), show_header: false})
  end

  defp option_rows(html) do
    Regex.scan(~r/class="([^"]*(?:q-option|items-start)[^"]*)"/, html)
    |> Enum.map(&List.last/1)
  end

  test "the option rows keep their box once the question is answered" do
    pending = render_block(msg(%{}))
    settled = render_block(msg(%{done: ["q1"], selections: %{"q1" => ["Yes"]}}))

    for state <- [pending, settled], class <- option_rows(state), token <- @geometry do
      assert String.contains?(class, token),
             "an option row lost #{token} — settling must not change the row's box:\n#{class}"
    end
  end

  test "nothing in a settled question bleeds past the card's own gutter" do
    settled = render_block(msg(%{done: ["q1"], selections: %{"q1" => ["Yes"]}}))

    refute settled =~ "-mx-4",
           "a receipt that bleeds to the screen edge starts at a different left " <>
             "edge from the options it replaced"
  end

  test "the answered option is green and checked; the others stay, dimmed" do
    settled = render_block(msg(%{done: ["q1"], selections: %{"q1" => ["Yes"]}}))

    assert settled =~ "emerald", "the chosen option is confirmed in moss"
    assert settled =~ "Yes"
    assert settled =~ "No", "the options you didn't pick stay, so the card still reads as a record"
  end

  test "a settled question offers no way to answer it again" do
    settled = render_block(msg(%{done: ["q1"], selections: %{"q1" => ["Yes"]}}))

    refute settled =~ "answer_question_text"
    refute settled =~ "skip_question"
  end
end
