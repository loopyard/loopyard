defmodule LoopyardWeb.QuestionOptionInputTest do
  @moduledoc """
  Picking an option must land on the frame you tapped.

  The options were `<button phx-click>`s whose every visual state came from a
  server assign, so a tap round-tripped before anything moved — and a re-render
  arriving late (a streaming reply, another viewer) redrew them from server
  state that didn't have the draft yet, which is the "checks, then unchecks"
  flicker. These tests hold the shape that fixed it: a REAL input, so the
  browser owns selection and the styling is pure CSS.
  """
  use LoopyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias LoopyardWeb.Live.WorkspaceLive.Messages.Cards

  defp question_html(opts \\ []) do
    q = %{
      id: "q1",
      header: "",
      prompt: "Which way?",
      options: [
        %{label: "Left", description: "go left"},
        %{label: "Right", description: nil}
      ],
      multi: Keyword.get(opts, :multi, false)
    }

    msg = %{
      id: "m1",
      question_id: "ask1",
      status: :pending,
      questions: [q],
      selections: %{},
      done: []
    }

    render_component(&Cards.question_block/1, msg: msg, q: q, chat_path: "/chat")
  end

  test "an option is a real radio, not a button that needs the server" do
    html = question_html()

    assert html =~ ~r/<input[^>]+type="radio"/
    assert html =~ ~r/<input[^>]+value="Left"/

    # No per-tap event: the choice rides the form. A phx-click here would put a
    # round-trip back in front of the selection.
    refute html =~ ~r/phx-click="draft_question_option"/
  end

  test "multi-select uses checkboxes so the browser owns the whole set" do
    html = question_html(multi: true)

    assert html =~ ~r/<input[^>]+type="checkbox"/
    refute html =~ ~r/phx-click="toggle_question_option"[^>]*value="Left"/
  end

  test "the selected look is driven by :checked, not by a server assign" do
    html = question_html()

    # peer-checked compiles to a sibling combinator, so these only work while
    # the styled elements stay DIRECT siblings of the input.
    assert html =~ "peer sr-only"
    assert html =~ "peer-checked:"
  end

  test "the server is still told, so other viewers see the draft" do
    html = question_html()

    # Durability and multiplayer, off the form's change — nothing on screen
    # waits for it.
    assert html =~ ~s|phx-change="draft_question_option"|
  end
end
