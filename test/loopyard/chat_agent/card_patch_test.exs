defmodule Loopyard.ChatAgent.CardPatchTest do
  @moduledoc """
  The anti-clobber contract for card interactions: a draft/answer applied via
  `update_message_now` must survive a BUSY agent writing a summary built from
  state that predates it (the check appearing then vanishing read as
  "questions are busted").
  """
  use ExUnit.Case, async: false

  alias Loopyard.ChatAgent.MessageWindow

  setup do
    Loopyard.StateKeeper.ensure_tables!()
    id = "cardpatch-#{System.unique_integer([:positive])}"

    # A live "agent": any process registered under the id keeps the patch
    # outstanding (the real GenServer converges it; this one just exists).
    test = self()

    pid =
      spawn(fn ->
        Registry.register(Loopyard.ChatAgentRegistry, id, nil)
        send(test, :registered)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :registered

    on_exit(fn ->
      send(pid, :stop)
      :ets.delete(:chat_agents, id)
      :ets.match_delete(:card_patches, {{id, :_}, :_})
    end)

    msg = %{
      id: "cm1",
      role: :question,
      question_id: "cq",
      status: :pending,
      selections: %{},
      done: [],
      questions: [
        %{id: "q1", header: "", prompt: "?", options: [%{label: "A", description: nil}]}
      ],
      timestamp: DateTime.utc_now()
    }

    :ets.insert(:chat_agents, {id, %{id: id, name: "CardPatch", status: :idle, messages: [msg]}})
    %{id: id, msg: msg}
  end

  # A full ChatAgent state map for the given workspace + messages. Every field
  # summary/1 and the persistence path read must be present.
  defp agent_state(workspace_id, messages) do
    %{
      id: "agent-#{workspace_id}",
      name: "Persist",
      working_dir: "/tmp",
      bind_mount: nil,
      host_access: false,
      workspace_id: workspace_id,
      container: nil,
      workstation_identity: nil,
      started_at: DateTime.utc_now(),
      started_by: "test",
      last_activity_at: DateTime.utc_now(),
      status: :idle,
      messages: messages,
      tool_calls: 0,
      errors: 0,
      service_name: nil,
      model: nil,
      total_input_tokens: 0,
      total_output_tokens: 0,
      total_cache_read_tokens: 0,
      total_cost_usd: 0.0,
      active_tool: nil,
      turns: 0,
      claude_session_id: nil,
      rate_limit_status: nil,
      rate_limit_resets_at_ms: nil,
      rate_limit_type: nil,
      rate_limit_utilization: nil,
      auth_error: nil,
      failed_prompt: nil,
      prompt_hash: nil,
      context_utilization: nil,
      pending_sends: []
    }
  end

  test "a stale summary write cannot clobber a fresh card interaction", %{id: id, msg: msg} do
    :ok = MessageWindow.update_message_now(id, "cm1", %{selections: %{"q1" => ["A"]}})

    # Instantly visible to every ETS reader.
    [{^id, summary}] = :ets.lookup(:chat_agents, id)
    assert get_in(hd(summary.messages), [:selections, "q1"]) == ["A"]

    # A busy agent writes a summary from STALE state (no draft) — the exact
    # clobber race. summary/1 must re-apply the outstanding patch.
    stale_state = %{
      id: id,
      name: "CardPatch",
      working_dir: "/tmp",
      bind_mount: nil,
      host_access: false,
      workspace_id: nil,
      container: nil,
      workstation_identity: nil,
      started_at: DateTime.utc_now(),
      started_by: "test",
      last_activity_at: DateTime.utc_now(),
      status: :thinking,
      messages: [msg],
      tool_calls: 0,
      errors: 0,
      service_name: nil,
      model: nil,
      total_input_tokens: 0,
      total_output_tokens: 0,
      total_cache_read_tokens: 0,
      total_cost_usd: 0.0,
      active_tool: nil,
      turns: 0,
      claude_session_id: nil,
      rate_limit_status: nil,
      rate_limit_resets_at_ms: nil,
      rate_limit_type: nil,
      rate_limit_utilization: nil,
      auth_error: nil,
      failed_prompt: nil,
      prompt_hash: nil,
      context_utilization: nil,
      pending_sends: []
    }

    stale_summary = Loopyard.ChatAgent.summary(stale_state)
    reconciled = Enum.find(stale_summary.messages, &(&1[:id] == "cm1"))

    assert get_in(reconciled, [:selections, "q1"]) == ["A"],
           "summary/1 must re-apply outstanding card patches — stale state clobbered the draft"
  end

  test "answering a card is persisted and survives a log replay (#77)", %{} do
    Loopyard.StateKeeper.ensure_tables!()
    ws = "cardpersist-#{System.unique_integer([:positive])}"
    log_path = Loopyard.ChatAgent.Persistence.log_path(ws)
    on_exit(fn -> File.rm_rf(Path.dirname(log_path)) end)

    card = %{
      id: "cm-persist",
      role: :question,
      question_id: "cq",
      status: :pending,
      selections: %{},
      done: [],
      questions: [
        %{id: "q1", header: "", prompt: "?", options: [%{label: "A", description: nil}]}
      ],
      timestamp: DateTime.utc_now()
    }

    state = agent_state(ws, [card])

    # Seed the log with the agent + the pending card (as the live app does).
    :ok = Loopyard.ChatAgent.Persistence.persist_agent(state, &Loopyard.ChatAgent.summary/1)
    :ok = Loopyard.ChatAgent.Persistence.persist_message(state, card)

    # Answer it through the real handler.
    {:noreply, _} =
      Loopyard.ChatAgent.handle_cast(
        {:card_patch, "cm-persist",
         %{status: :answered, selections: %{"q1" => ["A"]}, card_v: 1}},
        state
      )

    # Replaying the durable log must bring the card back ANSWERED, not pending.
    assert {:ok, replayed} =
             Loopyard.AgentLog.replay(log_path: log_path, version: 1)

    restored_card =
      replayed[state.id].messages |> Enum.find(&(&1[:id] == "cm-persist"))

    assert restored_card[:status] == :answered,
           "the answer must survive a restart — it was only in ETS/memory (#77)"

    assert restored_card[:selections] == %{"q1" => ["A"]}
  end

  test "without a live agent the patch applies directly and leaves no record" do
    Loopyard.StateKeeper.ensure_tables!()
    id = "cardpatch-dead-#{System.unique_integer([:positive])}"

    msg = %{id: "cm2", role: :question, question_id: "cq2", status: :pending, selections: %{}}
    :ets.insert(:chat_agents, {id, %{id: id, name: "Dead", status: :crashed, messages: [msg]}})
    on_exit(fn -> :ets.delete(:chat_agents, id) end)

    :ok = MessageWindow.update_message_now(id, "cm2", %{status: :answered})

    [{^id, summary}] = :ets.lookup(:chat_agents, id)
    assert hd(summary.messages)[:status] == :answered
    assert :ets.match_object(:card_patches, {{id, :_}, :_}) == []
  end
end
