defmodule Loopyard.ChatAgent.ResumeMessageTest do
  use ExUnit.Case, async: true

  alias Loopyard.ChatAgent.ResumeMessage

  test "nil when there's too little history to seed" do
    assert ResumeMessage.build([]) == nil
    assert ResumeMessage.build([%{role: :user, content: "hi"}]) == nil
  end

  test "replays recent turns VERBATIM, oldest→newest, and points at recall_conversation" do
    # newest-first (live GenServer order)
    msgs = [
      %{role: :assistant, content: "the answer is 42"},
      %{role: :user, content: "what is the answer"},
      %{role: :tool, tool: "grep", content: "BULKY tool output that should be skipped"},
      %{role: :assistant, content: "let me check"},
      %{role: :user, content: "start the task"}
    ]

    out = ResumeMessage.build(msgs)

    assert out =~ "continuing an existing conversation"
    assert out =~ "5 earlier message"
    # Verbatim content, not a summary.
    assert out =~ "the answer is 42"
    assert out =~ "what is the answer"
    # Bulky tool output is excluded from the seed (recall_conversation can fetch it).
    refute out =~ "BULKY tool output"
    # Oldest→newest ordering: the first user turn precedes the latest assistant turn.
    {oldest, _} = :binary.match(out, "start the task")
    {newest, _} = :binary.match(out, "the answer is 42")
    assert oldest < newest
    # Depth is a tool call away.
    assert out =~ "recall_conversation"
  end

  test "caps a giant message body (full text stays retrievable via recall)" do
    big = String.duplicate("x", 5000)
    out = ResumeMessage.build([%{role: :assistant, content: big}, %{role: :user, content: "hi"}])

    assert out =~ "truncated — call recall_conversation"
    refute out =~ String.duplicate("x", 2000)
  end
end
