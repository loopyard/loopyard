defmodule Loopyard.Harness.QuestionsWaiterlessTest do
  @moduledoc """
  A question entry with NO waiter is a supported state, and it must not crash
  anything that inspects it.

  The incident: `pending_for_agent/1` called `Process.alive?(entry.waiter)`,
  which raises `ArgumentError` when the waiter is nil. Waiterless entries exist
  by design — `with_entry/2` rebuilds a broker entry from a durable card so an
  ORPHANED card is still answerable (CLAUDE.md → Attention & the Reviewer). So
  the moment one existed, that raise landed in `ChatAgent.handle_cast` on the
  SEND path: every message to that agent killed the GenServer and disappeared
  with no error anywhere the user could see.

  Two properties, both of which the crash violated:

    * inspecting a waiterless entry never raises, and
    * it is not reaped — reaping it would break answering the card it was
      rebuilt for.
  """
  use ExUnit.Case, async: false

  alias Loopyard.Harness.Questions

  @table :harness_questions

  setup do
    agent_id = "waiterless-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      for {qid, e} <- :ets.tab2list(@table), e.agent_id == agent_id, do: :ets.delete(@table, qid)
    end)

    %{agent_id: agent_id}
  end

  defp put_entry(agent_id, waiter) do
    qid = "q-#{System.unique_integer([:positive])}"

    :ets.insert(
      @table,
      {qid,
       %{
         agent_id: agent_id,
         msg_id: "m-#{qid}",
         waiter: waiter,
         questions: [],
         selections: %{},
         done: []
       }}
    )

    qid
  end

  test "a waiterless entry does not raise and does not report the agent blocked", %{agent_id: id} do
    qid = put_entry(id, nil)

    # The bug: this raised ArgumentError instead of answering the question.
    assert Questions.pending_for_agent?(id) == false
    assert Questions.pending_for_agent(id) == nil

    # And it must survive: with_entry/2 rebuilt it so the card stays answerable.
    assert [{^qid, _}] = :ets.lookup(@table, qid)
  end

  test "a LIVE waiter still reports the agent blocked", %{agent_id: id} do
    parent = self()
    waiter = spawn(fn -> receive do: (:stop -> send(parent, :stopped)) end)
    qid = put_entry(id, waiter)

    assert {^qid, _} = Questions.pending_for_agent(id)
    assert Questions.pending_for_agent?(id)

    send(waiter, :stop)
    assert_receive :stopped, 500
  end

  test "a DEAD waiter is reaped — that entry really did leak", %{agent_id: id} do
    # The reap flips the CARD to :timeout, which needs a summary to patch.
    :ets.insert(
      :chat_agents,
      {id,
       %{
         id: id,
         name: "T",
         status: :idle,
         messages: [],
         working_dir: "/tmp",
         started_at: DateTime.utc_now(),
         last_activity_at: DateTime.utc_now()
       }}
    )

    on_exit(fn -> :ets.delete(:chat_agents, id) end)

    waiter = spawn(fn -> :ok end)
    Process.sleep(20)
    refute Process.alive?(waiter)

    qid = put_entry(id, waiter)

    assert Questions.pending_for_agent(id) == nil
    assert :ets.lookup(@table, qid) == []
  end
end
