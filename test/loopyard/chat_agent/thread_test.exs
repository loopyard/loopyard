defmodule Loopyard.ChatAgent.ThreadTest do
  @moduledoc """
  A message ABOUT a decision must keep its reference through every send path
  (the marker rides in the text), show without it, and hand the model the
  card instead of the marker.
  """
  use ExUnit.Case, async: true

  alias Loopyard.ChatAgent.Thread

  @ref {"abd14b70adbe0634", "FFiR9zZaR90"}

  test "tag/split round-trip, and plain text is left alone" do
    tagged = Thread.tag("what does option 2 change?", @ref)

    assert Thread.split(tagged) == {"what does option 2 change?", @ref}
    assert Thread.split("hello") == {"hello", nil}
    assert Thread.display(tagged) == "what does option 2 change?"
    assert Thread.display("hello") == "hello"
  end

  test "non-binary payloads pass through (send_message rejects them later)" do
    assert Thread.split(nil) == {nil, nil}
    assert Thread.split(42) == {42, nil}
  end

  test "user_message stamps `re` only when tagged" do
    assert %{role: :user, content: "hi", re: @ref} = Thread.user_message(Thread.tag("hi", @ref))
    refute Map.has_key?(Thread.user_message("hi"), :re)
  end

  test "frame_prompt degrades to the bare text when the card is gone" do
    # No such agent → no card → the model just gets the words.
    assert Thread.frame_prompt(Thread.tag("why?", {"no-such-agent", "nope"})) == "why?"
    assert Thread.frame_prompt("why?") == "why?"
  end

  describe "reply_re/1 (the assistant inherits the human's decision)" do
    # state.messages is newest-first.
    test "takes the newest user message's ref on a human turn" do
      state = %{
        current_turn_origin: :human,
        messages: [
          %{role: :tool, content: "…"},
          %{role: :user, content: "why?", re: @ref},
          %{role: :user, content: "older", re: {"x", "y"}}
        ]
      }

      assert Thread.reply_re(state) == @ref
    end

    test "nil when the newest user message is untagged" do
      state = %{current_turn_origin: :human, messages: [%{role: :user, content: "plain"}]}
      assert Thread.reply_re(state) == nil
    end

    test "never tags a seed / resume turn with whatever the human last asked about" do
      state = %{current_turn_origin: :seed, messages: [%{role: :user, content: "x", re: @ref}]}
      assert Thread.reply_re(state) == nil
    end
  end

  test "messages_for picks exactly the thread" do
    msgs = [
      %{role: :user, content: "a", re: @ref},
      %{role: :assistant, content: "b", re: @ref},
      %{role: :user, content: "c"},
      %{role: :assistant, content: "d", re: {"other", "1"}}
    ]

    assert Enum.map(Thread.messages_for(msgs, @ref), & &1.content) == ["a", "b"]
  end
end
