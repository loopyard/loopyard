defmodule LoopyardWeb.Live.WorkspaceLive.QuestionCardTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias LoopyardWeb.Live.WorkspaceLive.Messages.Cards

  defp pending_msg do
    %{
      question_id: "abc",
      status: :pending,
      selections: %{},
      questions: [
        %{
          id: "q1",
          header: "GH AUTH",
          prompt: "No GitHub credentials are available here. How do you want to authenticate?",
          options: [
            %{label: "Paste a token", description: "You give me a GitHub PAT (repo scope)."},
            %{label: "Hold off", description: "Don't publish yet."}
          ]
        }
      ]
    }
  end

  test "spans full width — the card is not capped at max-w-xl" do
    html = render_component(&Cards.question_card/1, %{msg: pending_msg()})
    refute html =~ "max-w-xl"
  end

  test "each option is a full-width click target with its description hugged beneath" do
    html = render_component(&Cards.question_card/1, %{msg: pending_msg()})

    # Full-width row (label is primary, whole row is the tap target).
    assert html =~ "w-full"
    assert html =~ "text-left"
    # Description is tightly bound under its label (subordinate via spacing).
    assert html =~ "mt-0.5"

    # Prompt + both options + their descriptions all render.
    assert html =~ "How do you want to authenticate?"
    assert html =~ "Paste a token"
    assert html =~ "You give me a GitHub PAT"
    assert html =~ "Hold off"
  end

  test "the commit action is the question footer, not inside the Other row" do
    html = render_component(&Cards.question_card/1, %{msg: pending_msg()})

    # ONE form wraps the whole question — option taps draft, the footer commits.
    assert length(String.split(html, ~s(phx-submit="answer_question_text"))) == 2

    # The Other row is just a draftable text input — no button lives inside it.
    [_, after_other] = String.split(html, ~s(placeholder="Other…"), parts: 2)
    [other_row_tail, _] = String.split(after_other, "</div>", parts: 2)
    refute other_row_tail =~ "<button"

    # The footer (after the Other row) carries Skip + the commit submit.
    assert after_other =~ ~s(type="submit")
    assert after_other =~ "Skip"
    # Match the submit button's LABEL, not a bare substring: "Answer" also
    # appears in "Answered" on the settled receipt, so a plain =~ would pass
    # even if the commit button vanished.
    assert after_other =~ ~r/type="submit".*?>\s*Answer\s*<\/button>/s
  end

  test "pending card offers Skip, Other free text, and the chat hint" do
    html = render_component(&Cards.question_card/1, %{msg: pending_msg()})

    assert html =~ "Skip"
    assert html =~ "Other…"
    assert html =~ "answer_question_text"
    assert html =~ "reply in the chat"
  end

  defp two_question_msg(done) do
    %{
      question_id: "abc",
      status: :pending,
      selections: %{"q1" => ["Paste a token"]},
      done: done,
      questions: [
        %{
          id: "q1",
          header: "GH AUTH",
          prompt: "How to authenticate?",
          options: [
            %{label: "Paste a token", description: nil},
            %{label: "Hold off", description: nil}
          ]
        },
        %{
          id: "q2",
          header: "SCOPE",
          prompt: "Which repos?",
          options: [
            %{label: "All", description: nil},
            %{label: "Just this one", description: nil}
          ]
        }
      ]
    }
  end

  test "a settled question locks while the rest stay interactive (no phantom answered)" do
    html = render_component(&Cards.question_card/1, %{msg: two_question_msg(["q1"])})

    # q1 locked: its chosen option lit, no more answer buttons for it.
    assert html =~ "Paste a token"
    # q2 still interactive: its options are buttons.
    assert html =~ "answer_question"
    assert html =~ "Which repos?"
    # progress counter in the header (tabular "answered/total")
    assert html =~ "1/2"
  end

  test "a skipped question shows a Skipped receipt, not answered" do
    msg = %{two_question_msg(["q1"]) | selections: %{"q1" => []}}
    html = render_component(&Cards.question_card/1, %{msg: msg})

    assert html =~ "Skipped"
    refute html =~ "✓ answered"
  end

  test "multi-select question toggles then confirms" do
    msg = %{
      question_id: "abc",
      status: :pending,
      selections: %{"q1" => ["A"]},
      questions: [
        %{
          id: "q1",
          header: "",
          prompt: "Pick any",
          multi: true,
          options: [%{label: "A", description: nil}, %{label: "B", description: nil}]
        }
      ]
    }

    html = render_component(&Cards.question_card/1, %{msg: msg})

    assert html =~ ~r/<input[^>]+type="checkbox"[^>]+value="A"[^>]+checked/
    assert html =~ ~r/<input[^>]+type="checkbox"[^>]+value="B"(?![^>]*checked)/
    assert html =~ ~s|phx-change="draft_question_option"|
    assert html =~ "confirm_question"
    assert html =~ "Done (1 selected)"
  end
end
