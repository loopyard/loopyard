defmodule Loopyard.Operator.JobsTest do
  use ExUnit.Case

  alias Loopyard.Operator.Jobs

  # Jobs is ETS-backed (:operator_jobs, owned by StateKeeper). The delta is
  # `msg_count(agent_id) - read_count`, where msg_count reads the agent's
  # summary from the shared :chat_agents table — so we seed fake summaries
  # there with unique agent ids and clean both tables up after.

  setup do
    Loopyard.StateKeeper.ensure_tables!()

    ws_id = "jobs-ws-#{System.unique_integer([:positive])}"
    agent_id = "jobs-agent-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Jobs.dismiss(ws_id)
      :ets.delete(:chat_agents, agent_id)
    end)

    %{ws_id: ws_id, agent_id: agent_id}
  end

  defp seed_messages(agent_id, count) do
    messages = for i <- 1..count//1, do: %{id: "m#{i}", role: :assistant, text: "msg #{i}"}
    :ets.insert(:chat_agents, {agent_id, %{messages: messages}})
  end

  describe "note_dispatch/2" do
    test "anchors read_count at the current message count so delta is 0", %{
      ws_id: ws_id,
      agent_id: agent_id
    } do
      seed_messages(agent_id, 3)

      assert :ok = Jobs.note_dispatch(ws_id, agent_id)

      job = Jobs.get(ws_id)
      assert %{agent_id: ^agent_id, read_count: 3} = job
      assert Jobs.delta(job) == 0
    end

    test "non-binary args are a no-op", %{ws_id: ws_id} do
      assert :ok = Jobs.note_dispatch(nil, nil)
      assert :ok = Jobs.note_dispatch(ws_id, :not_a_binary)
      assert Jobs.get(ws_id) == nil
    end
  end

  describe "delta/1" do
    test "rises with the message count", %{ws_id: ws_id, agent_id: agent_id} do
      seed_messages(agent_id, 3)
      Jobs.note_dispatch(ws_id, agent_id)

      # Two new messages arrive after the dispatch anchor.
      seed_messages(agent_id, 5)

      assert Jobs.delta(Jobs.get(ws_id)) == 2
    end

    test "clamps at 0 when the message count shrinks below the anchor", %{
      ws_id: ws_id,
      agent_id: agent_id
    } do
      seed_messages(agent_id, 5)
      Jobs.note_dispatch(ws_id, agent_id)

      # Transcript shrank (e.g. agent removed / log truncated) — never negative.
      seed_messages(agent_id, 2)

      assert Jobs.delta(Jobs.get(ws_id)) == 0
    end

    test "is 0 for a missing job slot" do
      assert Jobs.delta(nil) == 0

      assert Jobs.delta(Jobs.get("jobs-ws-nonexistent-#{System.unique_integer([:positive])}")) ==
               0
    end
  end

  describe "mark_read/1" do
    test "re-anchors read_count to now so delta resets", %{ws_id: ws_id, agent_id: agent_id} do
      seed_messages(agent_id, 3)
      Jobs.note_dispatch(ws_id, agent_id)
      seed_messages(agent_id, 7)
      assert Jobs.delta(Jobs.get(ws_id)) == 4

      assert :ok = Jobs.mark_read(ws_id)

      job = Jobs.get(ws_id)
      assert job.read_count == 7
      assert Jobs.delta(job) == 0
    end

    test "is a no-op for an unknown workspace" do
      assert :ok = Jobs.mark_read("jobs-ws-unknown-#{System.unique_integer([:positive])}")
    end
  end

  describe "dismiss/1" do
    test "removes the job slot", %{ws_id: ws_id, agent_id: agent_id} do
      seed_messages(agent_id, 1)
      Jobs.note_dispatch(ws_id, agent_id)
      assert Jobs.get(ws_id) != nil

      assert :ok = Jobs.dismiss(ws_id)

      assert Jobs.get(ws_id) == nil
      refute Enum.any?(Jobs.list(), fn {id, _job} -> id == ws_id end)
    end
  end
end
