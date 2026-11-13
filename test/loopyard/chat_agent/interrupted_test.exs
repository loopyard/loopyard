defmodule Loopyard.ChatAgent.InterruptedTest do
  @moduledoc """
  An agent a server restart cut off mid-turn (#119). Its row comes back marked
  `interrupted?` (`AgentLog.at_rest/1`); on resume a RECENT one re-drives its
  unanswered prompt once with one quiet line, an old one keeps the mark for the
  inbox (Continue / Dismiss), and an answered one has nothing to continue.
  """
  use Loopyard.AgentCase

  alias Loopyard.{ChatAgent, Fleet, Notifications}
  alias Loopyard.ChatAgent.Interrupted
  alias Loopyard.Fleet.Conditions
  alias Loopyard.TestSupport.RecordingBackend

  import Loopyard.TestHelpers, only: [eventually: 1]

  @moduletag timeout: 15_000

  setup do
    own_recording_backend()
    :ok
  end

  defp own_recording_backend do
    case Process.whereis(RecordingBackend) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)
        Process.unlink(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, _, _, _}, 1_000

      nil ->
        :ok
    end

    {:ok, _} = RecordingBackend.start_link()
  end

  defp opts(id, extra \\ []),
    do: [id: id, name: "Interrupted Test", started_by: "test", backend: RecordingBackend] ++ extra

  # Boot an agent, stop it, and leave its ETS row as a restored, interrupted
  # one: `messages` (oldest first) with the last activity `ago_ms` back.
  defp restored!(messages, ago_ms) do
    id = "int-#{System.unique_integer([:positive])}"
    {:ok, _} = Loopyard.TestHelpers.start_agent(opts(id))

    on_exit(fn ->
      try do
        ChatAgent.stop_agent(id)
      catch
        :exit, _ -> :ok
      end

      Notifications.settle(Conditions.item_id(id, :interrupted), :test_cleanup)
    end)

    ChatAgent.stop_agent(id)
    eventually(fn -> not Loopyard.Agents.alive?(id) end)

    at = DateTime.add(DateTime.utc_now(), -ago_ms, :millisecond)
    [{^id, row}] = :ets.lookup(:chat_agents, id)

    row =
      Map.merge(row, %{
        status: :idle,
        interrupted?: true,
        last_activity_at: at,
        messages: Enum.map(messages, &Map.put_new(&1, :timestamp, at))
      })

    :ets.insert(:chat_agents, {id, row})
    id
  end

  defp resume!(id) do
    {:ok, pid} = Loopyard.TestHelpers.start_agent(opts(id, resume: true))
    pid
  end

  defp user(text),
    do: %{id: "u-#{System.unique_integer([:positive])}", role: :user, content: text}

  defp reply(text),
    do: %{id: "a-#{System.unique_integer([:positive])}", role: :assistant, content: text}

  defp lines(pid),
    do:
      pid
      |> :sys.get_state()
      |> Map.get(:messages)
      |> Enum.count(&(&1[:role] == :system and &1[:content] == Interrupted.line()))

  defp streamed(text), do: Enum.count(RecordingBackend.streamed_prompts(), &(&1 == text))

  test "a recent interruption is re-driven once, with one quiet line" do
    id = restored!([user("hi"), reply("hello"), user("build the parser")], 60_000)
    pid = resume!(id)

    eventually(fn -> streamed("build the parser") == 1 end)
    assert lines(pid) == 1
    eventually(fn -> Loopyard.Agents.get(id)[:interrupted?] == false end)

    # Back from a SECOND restart that didn't cut a turn: nothing to re-drive.
    ChatAgent.stop_agent(id)
    eventually(fn -> not Loopyard.Agents.alive?(id) end)
    pid = resume!(id)
    :sys.get_state(pid)
    Process.sleep(50)
    assert streamed("build the parser") == 1
    assert lines(pid) == 1
  end

  test "a re-drive a second restart cut off is not driven again" do
    id =
      restored!(
        [
          reply("hello"),
          user("build the parser"),
          %{id: "s1", role: :system, content: Interrupted.line()},
          user("build the parser")
        ],
        60_000
      )

    pid = resume!(id)
    :sys.get_state(pid)
    Process.sleep(50)

    assert streamed("build the parser") == 0
    assert :sys.get_state(pid) |> Interrupted.marked?()
  end

  test "an interruption whose turn was already answered has nothing to continue" do
    id = restored!([user("build it"), reply("built")], 60_000)
    pid = resume!(id)
    :sys.get_state(pid)
    Process.sleep(50)

    assert RecordingBackend.streamed_prompts() == []
    refute Interrupted.marked?(:sys.get_state(pid))
    assert Loopyard.Agents.get(id)[:interrupted?] == false
  end

  test "an old interruption keeps its mark; Continue re-drives it and settles the item" do
    id = restored!([reply("hello"), user("migrate the db")], 2 * 60 * 60_000)
    pid = resume!(id)
    :sys.get_state(pid)

    assert streamed("migrate the db") == 0
    assert Loopyard.Agents.get(id)[:interrupted?] == true
    assert Conditions.of(Loopyard.Agents.get(id)) == :interrupted

    item = Conditions.item_id(id, :interrupted)
    Notifications.raise_item(Notifications.Item.stuck(id, :interrupted, "cut off", %{}))
    Notifications.sync()

    assert Fleet.continue(id) == :ok
    eventually(fn -> streamed("migrate the db") == 1 end)
    assert lines(pid) == 1
    Notifications.sync()
    assert %{status: :settled, outcome: :continued} = Notifications.get(item)
    refute Loopyard.Agents.get(id)[:interrupted?]
  end

  test "the chief of staff continues it with agent action=continue" do
    id = restored!([reply("hello"), user("write the docs")], 2 * 60 * 60_000)
    pid = resume!(id)
    :sys.get_state(pid)

    assert {:ok, msg} =
             Loopyard.Tools.ControlPlane.Agent.execute(
               %{agent_id: "op", target: id, action: "continue"},
               %{}
             )

    assert msg =~ "Continuing"
    eventually(fn -> streamed("write the docs") == 1 end)
  end

  test "Dismiss clears the mark of an asleep agent, in its row and its log" do
    id = restored!([reply("hello"), user("migrate the db")], 2 * 60 * 60_000)
    item = Conditions.item_id(id, :interrupted)
    Notifications.raise_item(Notifications.Item.stuck(id, :interrupted, "cut off", %{}))
    Notifications.sync()

    assert Fleet.dismiss(item, "Brad") == :ok
    Notifications.sync()

    assert %{status: :dismissed} = Notifications.get(item)
    assert Loopyard.Agents.get(id)[:interrupted?] == false
    assert Conditions.of(Loopyard.Agents.get(id)) == nil
  end

  describe "recent?/2" do
    test "the newest of last activity and the last message counts" do
      now = System.system_time(:millisecond)
      old = DateTime.from_unix!(now - 3 * 60 * 60_000, :millisecond)
      fresh = DateTime.from_unix!(now - 60_000, :millisecond)

      assert Interrupted.recent?(%{last_activity_at: old, messages: [%{timestamp: fresh}]}, now)
      refute Interrupted.recent?(%{last_activity_at: old, messages: [%{timestamp: old}]}, now)
      refute Interrupted.recent?(%{}, now)
    end
  end
end
