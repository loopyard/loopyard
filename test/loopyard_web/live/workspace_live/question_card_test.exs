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
    assert html =~ "w-full text-left"
    # Description is tightly bound under its label (subordinate via spacing).
    assert html =~ "mt-0.5"

    # Prompt + both options + their descriptions all render.
    assert html =~ "How do you want to authenticate?"
    assert html =~ "Paste a token"
    assert html =~ "You give me a GitHub PAT"
    assert html =~ "Hold off"
  end
end
