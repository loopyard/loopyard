defmodule Loopyard.ChatAgent.ModelControlTest do
  use ExUnit.Case

  alias Loopyard.ChatAgent.ModelControl

  # Backend exposing both set_model/2 and available_models/1 (adapter aliases
  # with descriptions). set_model reports back to the test process so we can
  # assert the live-switch call happened.
  defmodule FullBackend do
    def set_model(session, model_id), do: send(session, {:set_model_called, model_id})

    def available_models(_session) do
      [
        %{id: "opus", description: "Opus 4.6 · most capable"},
        %{id: "sonnet", description: "Sonnet 4.5 · balanced"},
        %{id: "nodesc", description: ""}
      ]
    end
  end

  # Backend WITHOUT set_model/2 or available_models/1 — switching must not crash.
  defmodule BareBackend do
    def noop, do: :ok
  end

  setup do
    Loopyard.StateKeeper.ensure_tables!()

    id = "model-control-#{System.unique_integer([:positive])}"
    on_exit(fn -> :ets.delete(:chat_agents, id) end)

    %{state: base_state(id), id: id}
  end

  # Minimal state satisfying ModelControl.switch/2 + ChatAgent.summary/1.
  # workspace_id and workstation_identity are nil so Persistence.persist_agent
  # is a no-op (no log path).
  defp base_state(id) do
    %{
      id: id,
      name: "model-test-agent",
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
      pending_sends: [],
      session: nil,
      backend: BareBackend,
      session_opts: []
    }
  end

  describe "switch/2" do
    test "persists :model into session_opts so a restart keeps it", %{state: state} do
      new_state = ModelControl.switch(state, "sonnet")

      assert Keyword.get(new_state.session_opts, :model) == "sonnet"
    end

    test "overwrites a previously chosen model in session_opts", %{state: state} do
      state = %{state | session_opts: [model: "opus", other: :kept]}

      new_state = ModelControl.switch(state, "sonnet")

      assert Keyword.get(new_state.session_opts, :model) == "sonnet"
      assert Keyword.get(new_state.session_opts, :other) == :kept
    end

    test "handles nil session_opts", %{state: state} do
      state = %{state | session_opts: nil}

      new_state = ModelControl.switch(state, "sonnet")

      assert Keyword.get(new_state.session_opts, :model) == "sonnet"
    end

    test "calls the backend's set_model/2 on a live session", %{state: state} do
      state = %{state | backend: FullBackend, session: self()}

      ModelControl.switch(state, "opus")

      assert_received {:set_model_called, "opus"}
    end

    test "a backend without set_model/2 doesn't crash", %{state: state} do
      state = %{state | backend: BareBackend, session: self()}

      new_state = ModelControl.switch(state, "sonnet")

      assert Keyword.get(new_state.session_opts, :model) == "sonnet"
      refute_received {:set_model_called, _}
    end

    test "does not call set_model/2 when there is no live session", %{state: state} do
      state = %{state | backend: FullBackend, session: nil}

      ModelControl.switch(state, "opus")

      refute_received {:set_model_called, _}
    end
  end

  describe "model label" do
    test "prefers the adapter description (first · segment) for a known alias", %{state: state} do
      state = %{state | backend: FullBackend, session: self()}

      new_state = ModelControl.switch(state, "opus")

      assert new_state.model == "Opus 4.6"
    end

    test "returns the id VERBATIM when not in the adapter list — no capitalization", %{
      state: state
    } do
      state = %{state | backend: FullBackend, session: self()}

      new_state = ModelControl.switch(state, "claude-opus-4-8")

      assert new_state.model == "claude-opus-4-8"
    end

    test "returns the id verbatim when the adapter description is empty", %{state: state} do
      state = %{state | backend: FullBackend, session: self()}

      new_state = ModelControl.switch(state, "nodesc")

      assert new_state.model == "nodesc"
    end

    test "returns the id verbatim when the backend has no available_models/1", %{state: state} do
      state = %{state | backend: BareBackend, session: self()}

      new_state = ModelControl.switch(state, "sonnet")

      assert new_state.model == "sonnet"
    end
  end
end
