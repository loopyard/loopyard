defmodule Loopyard.ChatAgent.PendingPromptTest do
  @moduledoc """
  Which prompt a recovery re-drives. `state.messages` is stored NEWEST first;
  the scan must walk back from the newest message to the last real answer.
  """
  use ExUnit.Case, async: true

  alias Loopyard.ChatAgent.Restart

  # Oldest first for readability, stored newest first like ChatAgent does.
  defp state(oldest_first), do: %{messages: Enum.reverse(oldest_first)}

  defp user(t), do: %{role: :user, content: t}
  defp answer(t), do: %{role: :assistant, content: t}

  test "the unanswered LAST prompt, never the conversation's first" do
    s = state([user("first"), answer("a1"), user("second")])
    assert Restart.pending_user_prompt(s) == "second"
  end

  test "nothing when the last turn was answered" do
    assert Restart.pending_user_prompt(state([user("q"), answer("a")])) == nil
    assert Restart.pending_user_prompts(state([user("q"), answer("a")])) == []
  end

  test "the whole unanswered run, oldest first, looking past system lines and a partial" do
    s =
      state([
        user("old"),
        answer("done"),
        user("one"),
        user("two"),
        %{role: :system, content: "Hit your limit"},
        %{role: :assistant, content: "half an ans", partial: true}
      ])

    assert Restart.pending_user_prompts(s) == ["one", "two"]
    assert Restart.pending_user_prompt(s) == "two"
  end
end
