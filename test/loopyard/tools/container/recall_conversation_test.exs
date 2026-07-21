defmodule Loopyard.Tools.Container.RecallConversationTest do
  use ExUnit.Case, async: false

  alias Loopyard.Tools.Container.RecallConversation

  # Seed the :chat_agents ETS table directly (the durable read path the tool
  # uses via MessageWindow) — no live GenServer needed.
  setup do
    Loopyard.StateKeeper.ensure_tables!()
    id = "recall_test_#{:erlang.unique_integer([:positive])}"

    msgs =
      for i <- 1..25 do
        %{
          id: "m#{i}",
          role: if(rem(i, 2) == 0, do: :assistant, else: :user),
          content: "message number #{i} about #{if i == 7, do: "pineapples", else: "things"}",
          timestamp: ~U[2026-07-20 12:00:00Z]
        }
      end

    :ets.insert(:chat_agents, {id, %{id: id, messages: msgs}})
    on_exit(fn -> :ets.delete(:chat_agents, id) end)
    %{id: id}
  end

  test "default page returns the most recent `limit` messages, oldest first", %{id: id} do
    {:ok, out} = RecallConversation.execute(%{agent_id: id, limit: 10}, %{})
    assert out =~ "25 message(s) total, showing 10"
    assert out =~ "message number 25"
    assert out =~ "message number 16"
    refute out =~ "message number 15"
    # Footer cursor = the earliest shown message, for paging further back.
    assert out =~ "before_id=m16"
  end

  test "before_id pages further back", %{id: id} do
    {:ok, out} = RecallConversation.execute(%{agent_id: id, limit: 5, before_id: "m16"}, %{})
    assert out =~ "message number 15"
    assert out =~ "message number 11"
    refute out =~ "message number 16"
    assert out =~ "before_id=m11"
  end

  test "query searches message content (case-insensitive)", %{id: id} do
    {:ok, out} = RecallConversation.execute(%{agent_id: id, query: "PINEAPPLES"}, %{})
    assert out =~ "1 match"
    assert out =~ "message number 7"
    refute out =~ "message number 8"
  end

  test "showing the whole conversation reports the beginning", %{id: id} do
    {:ok, out} = RecallConversation.execute(%{agent_id: id, limit: 100}, %{})
    assert out =~ "showing 25"
    assert out =~ "beginning of the conversation"
    refute out =~ "before_id="
  end

  test "empty history" do
    id = "recall_empty_#{:erlang.unique_integer([:positive])}"
    :ets.insert(:chat_agents, {id, %{id: id, messages: []}})
    on_exit(fn -> :ets.delete(:chat_agents, id) end)
    {:ok, out} = RecallConversation.execute(%{agent_id: id}, %{})
    assert out =~ "No conversation history yet"
  end

  test "reads by the agent_id it is given (identity is bound by ToolRouter, not payload)", %{
    id: id
  } do
    # A different agent's id returns THAT agent's history — the security property
    # (agent can only read its OWN) is enforced upstream by ToolRouter forcing
    # agent_id from the bearer token. Here we just confirm the tool honors the id.
    {:ok, out} = RecallConversation.execute(%{agent_id: id}, %{agent_id: id})
    assert out =~ "message number 25"
  end
end
