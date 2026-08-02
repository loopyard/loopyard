defmodule Loopyard.Tools.Container.RecallConversationTest do
  @moduledoc """
  Recall has to be USEFUL without blowing the context it's restoring.

  Two failure modes, both real:

    * The per-message cap bounded nothing in aggregate — 200 messages x 800
      bytes is ~160KB, roughly 40k tokens, dumped by a single call into the
      context this tool exists to protect.

    * Search truncated each hit to its FIRST 800 bytes, so a match 3KB into a
      long message was located and then hidden. Finding something and not
      showing it is worse than not finding it: the agent reports it looked.
  """
  use ExUnit.Case, async: false

  alias Loopyard.Tools.Container.RecallConversation

  setup do
    id = "recall-#{System.unique_integer([:positive])}"
    on_exit(fn -> :ets.delete(:chat_agents, id) end)
    %{id: id}
  end

  defp seed(id, messages) do
    :ets.insert(
      :chat_agents,
      {id,
       %{
         id: id,
         name: "T",
         status: :idle,
         working_dir: "/tmp",
         started_at: DateTime.utc_now(),
         last_activity_at: DateTime.utc_now(),
         messages: messages
       }}
    )
  end

  defp msg(i, content, extra \\ %{}) do
    Map.merge(
      %{
        id: "m#{i}",
        role: :user,
        content: content,
        timestamp: DateTime.add(~U[2026-01-01 00:00:00Z], i, :second)
      },
      extra
    )
  end

  test "a big history cannot blow the context window", %{id: id} do
    # 200 messages of 2KB each — 400KB of raw history.
    seed(id, for(i <- 1..200, do: msg(i, String.duplicate("x", 2_000))))

    {:ok, out} = RecallConversation.execute(%{agent_id: id, limit: 200}, %{})

    assert byte_size(out) < 20_000,
           "recall returned #{byte_size(out)} bytes — it must stay within its budget"

    assert out =~ "omitted to stay within the context budget",
           "when it drops messages it has to SAY so, and say how to reach them"
  end

  test "it keeps the NEWEST messages when it has to drop some", %{id: id} do
    seed(
      id,
      for(i <- 1..100, do: msg(i, "marker-#{i} " <> String.duplicate("y", 1_000)))
    )

    {:ok, out} = RecallConversation.execute(%{agent_id: id, limit: 100}, %{})

    assert out =~ "marker-100", "the most recent message must survive"
    refute out =~ "marker-1 y", "the oldest should be the first to go"
  end

  test "search shows the MATCH, not the head of the message", %{id: id} do
    buried =
      String.duplicate("filler ", 600) <> "SECRET-TOKEN-abc123" <> String.duplicate(" tail", 200)

    seed(id, [msg(1, "hello"), msg(2, buried)])

    {:ok, out} = RecallConversation.execute(%{agent_id: id, query: "SECRET-TOKEN"}, %{})

    assert out =~ "SECRET-TOKEN-abc123",
           "the match was found but truncated away — the whole point is to SHOW it"
  end

  test "search requires ALL terms, in any order", %{id: id} do
    seed(id, [
      msg(1, "the dev key is here"),
      msg(2, "dev environment only"),
      msg(3, "a key by itself")
    ])

    {:ok, out} = RecallConversation.execute(%{agent_id: id, query: "key dev"}, %{})

    assert out =~ "the dev key is here"
    refute out =~ "dev environment only"
    refute out =~ "a key by itself"
  end

  test "search covers tool names too", %{id: id} do
    seed(id, [msg(1, "ran it", %{role: :tool, tool: "docker_compose"})])

    {:ok, out} = RecallConversation.execute(%{agent_id: id, query: "docker_compose"}, %{})
    assert out =~ "1 match"
  end

  describe "grep (regex)" do
    test "matches on SHAPE, which plain words can't", %{id: id} do
      seed(id, [
        msg(1, "the token is sk-ant-oat01-AbCdEf0123456789xyzQ"),
        msg(2, "no secrets in this one")
      ])

      {:ok, out} =
        RecallConversation.execute(%{agent_id: id, pattern: "sk-[A-Za-z0-9-]{20,}"}, %{})

      assert out =~ "1 match"
      assert out =~ "sk-ant-oat01"
      refute out =~ "no secrets in this one"
    end

    test "is case-insensitive by default and can be made strict", %{id: id} do
      seed(id, [msg(1, "The DEV Key is here")])

      {:ok, loose} = RecallConversation.execute(%{agent_id: id, pattern: "dev key"}, %{})
      assert loose =~ "1 match"

      {:ok, strict} =
        RecallConversation.execute(%{agent_id: id, pattern: "dev key", case_sensitive: true}, %{})

      assert strict =~ "0 match"
    end

    test "centres the excerpt on the regex match, not the head", %{id: id} do
      buried = String.duplicate("filler ", 600) <> "PASSWORD=hunter2sekrit"
      seed(id, [msg(1, buried)])

      {:ok, out} = RecallConversation.execute(%{agent_id: id, pattern: "PASSWORD\\s*="}, %{})

      assert out =~ "hunter2sekrit",
             "grep found it but truncated it away — the point is to SHOW the match"
    end

    test "an invalid pattern explains itself instead of crashing", %{id: id} do
      seed(id, [msg(1, "hello")])

      {:ok, out} = RecallConversation.execute(%{agent_id: id, pattern: "(unclosed"}, %{})

      assert out =~ "Invalid pattern"
      assert out =~ "query", "it should point at the simpler alternative"
    end

    test "greps tool names too", %{id: id} do
      seed(id, [msg(1, "ran it", %{role: :tool, tool: "docker_compose"})])

      {:ok, out} =
        RecallConversation.execute(%{agent_id: id, pattern: "docker_(compose|build)"}, %{})

      assert out =~ "1 match"
    end

    test "grep output is bounded like everything else", %{id: id} do
      seed(id, for(i <- 1..200, do: msg(i, "hit-#{i} " <> String.duplicate("z", 2_000))))

      {:ok, out} =
        RecallConversation.execute(%{agent_id: id, pattern: "hit-\\d+", limit: 200}, %{})

      assert byte_size(out) < 20_000, "grep returned #{byte_size(out)} bytes"
    end
  end

  test "every message carries its id, so the agent can page from any of them", %{id: id} do
    seed(id, for(i <- 1..3, do: msg(i, "line #{i}")))

    {:ok, out} = RecallConversation.execute(%{agent_id: id}, %{})
    assert out =~ "(id m3)"
  end
end
