defmodule Loopyard.ChatAgent.QueueAckTest do
  @moduledoc """
  A send to a BUSY agent whose pending queue is full must NOT be acked as
  success (issue #78). The synchronous send path replied `:ok` even when
  `park_send` dropped the message, so the browser cleared the input and
  deleted the draft — silent loss, the outcome SendGuards calls unforgivable.
  """
  use ExUnit.Case, async: false

  alias Loopyard.ChatAgent
  alias Loopyard.ChatAgent.SendGuards

  setup do
    Loopyard.StateKeeper.ensure_tables!()
    :ok
  end

  defp busy_state(pending) do
    %{
      id: "queueack-#{System.unique_integer([:positive])}",
      name: "Q",
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
      messages: [],
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
      pending_sends: pending
    }
  end

  test "a full queue on a busy agent replies {:error, :queue_full}, not :ok" do
    full = for i <- 1..50, do: "queued #{i}"
    state = busy_state(full)

    assert {:reply, reply, _new_state} =
             ChatAgent.handle_call({:send_message, "one too many"}, {self(), make_ref()}, state)

    assert reply == {:error, :queue_full},
           "a dropped message must be reported, not laundered into :ok"
  end

  test "a non-full queue on a busy agent replies :ok and enqueues" do
    state = busy_state(["a", "b"])

    assert {:reply, :ok, new_state} =
             ChatAgent.handle_call({:send_message, "c"}, {self(), make_ref()}, state)

    assert new_state.pending_sends == ["a", "b", "c"]
  end

  test "SendGuards.park_send still reports :full at the cap (unchanged contract)" do
    assert :full = SendGuards.park_send(busy_state(for(_ <- 1..50, do: "x")), "y")
  end
end
