defmodule Loopyard.ChatAgent.HarnessControlTest do
  @moduledoc """
  Switching an agent between harnesses. The subtle parts are what must NOT
  survive the switch (the native session id, the old harness's model id) and
  what must (the conversation, via Loopyard's durable log).
  """
  use ExUnit.Case, async: true

  alias Loopyard.ChatAgent.HarnessControl

  setup do
    Loopyard.StateKeeper.ensure_tables!()

    id = "harness-control-#{System.unique_integer([:positive])}"
    on_exit(fn -> :ets.delete(:chat_agents, id) end)

    {:ok, state: base_state(id)}
  end

  # switch/3 writes through ChatAgent.summary/1, so the state has to satisfy it.
  # workspace_id + workstation_identity nil keeps Persistence.persist_agent a
  # no-op (no log path to write).
  defp base_state(id) do
    %{
      id: id,
      name: "harness-test-agent",
      working_dir: nil,
      bind_mount: nil,
      host_access: false,
      workspace_id: nil,
      container: nil,
      workstation_identity: nil,
      started_at: DateTime.utc_now(),
      started_by: nil,
      last_activity_at: DateTime.utc_now(),
      status: :idle,
      messages: [],
      tool_calls: 0,
      errors: 0,
      service_name: nil,
      model: "Opus 4.8",
      total_input_tokens: 0,
      total_output_tokens: 0,
      total_cache_read_tokens: 0,
      total_cost_usd: 0.0,
      active_tool: nil,
      turns: 0,
      claude_session_id: "sess-abc",
      rate_limit_status: nil,
      rate_limit_resets_at_ms: nil,
      rate_limit_type: nil,
      rate_limit_utilization: nil,
      auth_error: nil,
      failed_prompt: nil,
      prompt_hash: nil,
      context_utilization: nil,
      pending_sends: [],
      session: nil,
      backend: Loopyard.Harness.Fake,
      session_opts: [harness: :claude, model: "claude-opus-4-8"]
    }
  end

  defp full(state), do: state

  describe "current/1" do
    test "reads the harness out of session_opts", %{state: state} do
      assert HarnessControl.current(state) == :claude
    end

    test "defaults when session_opts is missing or silent" do
      assert HarnessControl.current(%{}) == :claude
      assert HarnessControl.current(%{session_opts: nil}) == :claude
      assert HarnessControl.current(%{session_opts: []}) == :claude
    end
  end

  describe "switch/3" do
    test "switching to the harness you are already on is a no-op, not a restart",
         %{state: state} do
      # Users click the row they're already on. Tearing down a healthy session
      # for that would be an expensive surprise.
      assert {^state, :noop} = HarnessControl.switch(full(state), :claude)
    end

    test "drops the previous harness's model rather than carrying it across",
         %{state: state} do
      {switched, :restart} = HarnessControl.switch(full(state), :codex)

      # "claude-opus-4-8" handed to codex-acp is a set_model rejection, not a
      # slow path — the agent would fail to start on a model nobody picked.
      refute Keyword.has_key?(switched.session_opts, :model)
      assert switched.model == nil
      assert Keyword.get(switched.session_opts, :harness) == :codex
    end

    test "an explicit model for the target harness is applied", %{state: state} do
      {switched, :restart} = HarnessControl.switch(full(state), :codex, "gpt-x")

      assert Keyword.get(switched.session_opts, :model) == "gpt-x"
      assert switched.model == "gpt-x"
    end

    test "an unknown harness resolves to the default instead of raising",
         %{state: state} do
      state = %{state | session_opts: [harness: :codex]}
      {switched, :restart} = HarnessControl.switch(full(state), "nonsense")

      assert Keyword.get(switched.session_opts, :harness) == :claude
    end
  end
end
