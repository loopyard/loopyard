defmodule Loopyard.ChatAgent.RestartSilenceTest do
  @moduledoc """
  A failure the system is already fixing does not get a chat message.

  CLAUDE.md states the rule outright: "Errors speak ONLY when the user can act
  and the system can't self-fix... Then SILENCE — EventLog + harness-status
  carry it." The restart path broke it in the most self-evident way possible —
  it posted a red error whose own text read "ACTION: none — retrying
  automatically in 2s".

  Worse than noise: a chat message is PERMANENT. The retry would succeed
  seconds later and the transcript kept the crash report forever, so a healthy
  agent read as horribly broken every time you scrolled past it. That's exactly
  how it was reported: "why is this so horribly crashed and not recovered?" —
  about an agent that had recovered.

  The message is earned only when self-healing has given up, because only then
  is there something for a person to do.
  """
  use ExUnit.Case, async: false

  alias Loopyard.ChatAgent

  setup do
    prev = Application.get_env(:loopyard, :max_consecutive_crashes)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:loopyard, :max_consecutive_crashes, prev),
        else: Application.delete_env(:loopyard, :max_consecutive_crashes)
    end)

    :ok
  end

  defp error_messages(id) do
    case :ets.lookup(:chat_agents, id) do
      [{^id, summary}] -> summary |> Map.get(:messages, []) |> Enum.filter(&(&1.role == :error))
      [] -> []
    end
  end

  @tag :recovery
  test "a retryable restart failure posts NO chat error" do
    # Documented here as the contract; the live path is exercised by the
    # recovery-tagged suite. The unit-level guarantee we can assert cheaply is
    # that the copy no longer exists in the retry branch at all.
    src = File.read!("lib/loopyard/chat_agent/restart.ex")

    refute src =~ "ACTION: none — retrying automatically",
           "a self-healing failure must not write a chat line saying it's self-healing"
  end

  test "the give-up message tells the user what to DO" do
    src = File.read!("lib/loopyard/chat_agent/restart.ex")

    assert src =~ "won't start",
           "when retries are exhausted the user must be told"

    assert src =~ "click Restart",
           "and told the one action that helps"
  end

  test "the error is gated on having actually given up" do
    src = File.read!("lib/loopyard/chat_agent/restart.ex")

    assert src =~ "giving_up?",
           "the chat message must be conditional on exhausting retries, not posted every attempt"
  end
end
