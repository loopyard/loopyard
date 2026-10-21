defmodule Loopyard.ChatAgent.ModeControlTest do
  use ExUnit.Case

  alias Loopyard.ChatAgent.ModeControl

  # Backend with the optional mode surface (what Harness.ACP exposes). set_mode
  # reports to the test process so the live switch can be asserted.
  defmodule ModeBackend do
    def set_mode(session, mode_id), do: send(session, {:set_mode_called, mode_id})

    def modes(_session) do
      %{
        current: "default",
        boot: "default",
        plan: "plan",
        available: [%{id: "default", name: "Manual"}, %{id: "plan", name: "Plan"}]
      }
    end
  end

  # A harness whose session advertises NO plan mode.
  defmodule NoPlanBackend do
    def set_mode(session, mode_id), do: send(session, {:set_mode_called, mode_id})
    def modes(_session), do: %{current: "default", boot: "default", plan: nil, available: []}
  end

  # No mode surface at all — switching must not crash.
  defmodule BareBackend do
    def noop, do: :ok
  end

  setup do
    Loopyard.StateKeeper.ensure_tables!()

    id = "mode-control-#{System.unique_integer([:positive])}"
    on_exit(fn -> :ets.delete(:chat_agents, id) end)

    %{state: base_state(id), id: id}
  end

  # Minimal state satisfying ModeControl + ChatAgent.summary/1. workspace_id
  # and workstation_identity are nil so Persistence.persist_agent is a no-op.
  defp base_state(id) do
    %{
      id: id,
      name: "mode-test-agent",
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
      mode: :build,
      plan_mode_id: "plan",
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
    test "Discuss puts the live session in plan mode and persists it for the next one",
         %{state: state} do
      state = %{state | backend: ModeBackend, session: self()}

      new_state = ModeControl.switch(state, :discuss)

      assert_received {:set_mode_called, "plan"}
      assert new_state.mode == :discuss
      assert Keyword.get(new_state.session_opts, :mode) == "plan"
    end

    test "Build returns to the boot mode and drops the persisted setting", %{state: state} do
      state = %{state | backend: ModeBackend, session: self(), mode: :discuss}
      state = %{state | session_opts: [mode: "plan", model: "opus"]}

      new_state = ModeControl.switch(state, :build)

      assert_received {:set_mode_called, "default"}
      assert new_state.mode == :build
      refute Keyword.has_key?(new_state.session_opts, :mode)
      assert Keyword.get(new_state.session_opts, :model) == "opus"
    end

    test "the setting lands in ETS and is broadcast so every viewer flips", %{
      state: state,
      id: id
    } do
      Loopyard.Events.ChatAgent.subscribe()

      ModeControl.switch(state, :discuss)

      assert [{^id, %{mode: :discuss, plan_mode_id: "plan"}}] = :ets.lookup(:chat_agents, id)
      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id}
    end

    test "Discuss on a harness without a plan mode stays on Build", %{state: state} do
      state = %{state | backend: NoPlanBackend, session: self(), plan_mode_id: nil}

      new_state = ModeControl.switch(state, :discuss)

      refute_received {:set_mode_called, _}
      assert new_state.mode == :build
      refute Keyword.has_key?(new_state.session_opts, :mode)
    end

    test "a backend without set_mode/2 doesn't crash; the setting still persists",
         %{state: state} do
      state = %{state | backend: BareBackend, session: self()}

      new_state = ModeControl.switch(state, :discuss)

      refute_received {:set_mode_called, _}
      assert new_state.mode == :discuss
      assert Keyword.get(new_state.session_opts, :mode) == "plan"
    end

    test "does not touch the backend when there is no live session", %{state: state} do
      state = %{state | backend: ModeBackend, session: nil}

      ModeControl.switch(state, :discuss)

      refute_received {:set_mode_called, _}
    end

    test "handles nil session_opts", %{state: state} do
      new_state = ModeControl.switch(%{state | session_opts: nil}, :discuss)
      assert Keyword.get(new_state.session_opts, :mode) == "plan"
    end
  end

  describe "capture/1" do
    test "learns the new session's plan mode", %{state: state} do
      state = %{state | backend: ModeBackend, session: self(), plan_mode_id: nil}
      assert ModeControl.capture(state).plan_mode_id == "plan"
    end

    test "a Discuss setting the new harness can't honour falls back to Build", %{state: state} do
      state = %{state | backend: NoPlanBackend, session: self(), mode: :discuss}
      state = %{state | session_opts: [mode: "plan"]}

      captured = ModeControl.capture(state)

      assert captured.plan_mode_id == nil
      assert captured.mode == :build
      refute Keyword.has_key?(captured.session_opts, :mode)
    end

    test "a backend without modes/1 leaves the fields alone", %{state: state} do
      state = %{state | backend: BareBackend, session: self(), mode: :discuss}
      assert ModeControl.capture(state).mode == :discuss
      assert ModeControl.capture(state).plan_mode_id == "plan"
    end

    test "no session → no-op", %{state: state} do
      assert ModeControl.capture(%{state | session: nil}) == %{state | session: nil}
    end
  end

  describe "parse/1" do
    test "accepts the UI's strings and the atoms" do
      assert ModeControl.parse("discuss") == {:ok, :discuss}
      assert ModeControl.parse("build") == {:ok, :build}
      assert ModeControl.parse(:discuss) == {:ok, :discuss}
      assert ModeControl.parse("plan") == :error
      assert ModeControl.parse(nil) == :error
    end
  end
end
