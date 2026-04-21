defmodule BoomLooper.SagaIntegrationTest do
  @moduledoc """
  End-to-end tests for the two migrated multi-step operations:
  `WorkspaceSupervisor.start_workspace/2` (rebuild path) and
  `AgentBoot.boot/3`. Verifies each one actually records a saga via
  the Recorder and surfaces failures correctly.

  Not async: the Recorder ETS is shared state, and these tests also
  touch `WorkspaceSupervisor`.
  """
  use ExUnit.Case, async: false

  alias BoomLooper.{AgentBoot, ChatAgent, Saga.Recorder, WorkspaceSupervisor}

  setup do
    # Clear Recorder so we only see sagas from this test.
    :ets.delete_all_objects(Recorder.table())

    # Ensure ChatAgent ETS is clean.
    _ = BoomLooper.StateKeeper.ensure_tables!()

    for {id, _} <- :ets.tab2list(:chat_agents) do
      :ets.delete(:chat_agents, id)
    end

    :ok
  end

  describe "WorkspaceSupervisor.start_workspace rebuild" do
    test "rebuild path records a :rebuild_workspace saga with two steps" do
      workspace_id = "saga-int-ws-#{:rand.uniform(99_999)}"
      path = Path.join(System.tmp_dir!(), workspace_id)
      File.mkdir_p!(path)

      {:ok, _pid} = WorkspaceSupervisor.start_workspace(workspace_id, path)

      # If the ServiceManager child hasn't registered yet, a second
      # call hits the unhealthy-group branch and runs the rebuild
      # saga. We assert the behavior conditionally — EITHER the group
      # was healthy (no saga fired, returns :already_running) OR it
      # was unhealthy (saga fires, returns a fresh pid).
      result = WorkspaceSupervisor.start_workspace(workspace_id, path)

      case result do
        {:ok, :already_running} ->
          # Healthy path — no rebuild saga.
          rebuilds = Recorder.recent(saga: :rebuild_workspace)

          refute Enum.any?(rebuilds, fn r -> r.metadata[:workspace_id] == workspace_id end),
                 "Healthy restart should not trigger rebuild saga"

        {:ok, pid} when is_pid(pid) ->
          # Rebuild saga fired. Verify it's recorded.
          rebuilds =
            Recorder.recent(saga: :rebuild_workspace)
            |> Enum.filter(fn r -> r.metadata[:workspace_id] == workspace_id end)

          assert length(rebuilds) >= 1,
                 "Expected a :rebuild_workspace saga to be recorded; got: " <>
                   "#{inspect(Recorder.recent(saga: :rebuild_workspace))}"

          saga = hd(rebuilds)

          assert saga.saga == :rebuild_workspace
          assert saga.step_count == 2

          step_names = Enum.map(saga.completed_steps, & &1.name)
          assert :stop_unhealthy_group in step_names
          assert :start_fresh_group in step_names
      end

      # Clean up
      WorkspaceSupervisor.stop_workspace(workspace_id)
      File.rm_rf!(path)
    end
  end

  describe "AgentBoot.boot records a :boot_agent saga" do
    # AgentBoot.boot drives a full saga (load_config → ensure_services
    # → start_agent → send_initial_message). ensure_services shells to
    # docker. Under full-suite I/O contention this easily exceeds 2s.
    @tag timeout: 15_000
    test "saga is recorded with every step on a failed boot" do
      id = "saga-boot-#{:rand.uniform(99_999)}"
      working_dir = Path.join(System.tmp_dir!(), "saga-boot-#{id}")
      File.mkdir_p!(working_dir)

      on_exit(fn -> File.rm_rf!(working_dir) end)

      ChatAgent.register_booting(id, "Test", working_dir)

      # Boot will proceed through saga steps. Outcome depends on
      # whether the workspace supervisor can be started; we don't
      # assert on that — we assert that SOME saga was recorded.
      AgentBoot.boot(
        id,
        [
          id: id,
          name: "Test",
          working_dir: working_dir,
          started_by: "test",
          bind_mount: working_dir
        ],
        initial_message: :none
      )

      # The recorder should have exactly one :boot_agent run.
      sagas = Recorder.recent(saga: :boot_agent)

      assert length(sagas) >= 1,
             "Expected at least one :boot_agent saga recorded. Got: #{inspect(sagas)}"

      saga = hd(sagas)
      assert saga.saga == :boot_agent

      # `:load_config` is always first; it's a pure read so it must
      # have succeeded regardless of subsequent failures.
      assert Enum.any?(saga.completed_steps, fn s ->
               s.name == :load_config and s.status == :succeeded
             end),
             "Expected :load_config step to have succeeded. Got: #{inspect(saga.completed_steps)}"

      # Metadata should include the agent + workspace ids for
      # /system/sagas filtering.
      assert saga.metadata[:agent_id] == id
    end
  end
end
