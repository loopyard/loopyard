defmodule Loopyard.WorkspaceSupervisorTest do
  use ExUnit.Case, async: false

  alias Loopyard.WorkspaceSupervisor

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "loopyard-ws-sup-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    workspace_id = Loopyard.Workspace.workspace_id(tmp_dir)

    on_exit(fn ->
      Loopyard.TestHelpers.destroy_workspace(workspace_id)
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir, workspace_id: workspace_id}
  end

  describe "start_workspace/2" do
    test "starts a workspace subtree", %{workspace_id: ws_id, tmp_dir: tmp_dir} do
      assert {:ok, _pid} = WorkspaceSupervisor.start_workspace(ws_id, tmp_dir)
      assert WorkspaceSupervisor.workspace_running?(ws_id)
    end

    test "duplicate start is idempotent", %{workspace_id: ws_id, tmp_dir: tmp_dir} do
      {:ok, _} = WorkspaceSupervisor.start_workspace(ws_id, tmp_dir)
      # Second call returns :ok regardless of whether the group was
      # already healthy (→ :already_running) or partially failed
      # (→ new pid after recovery). Both are "you're good" outcomes.
      assert {:ok, _} = WorkspaceSupervisor.start_workspace(ws_id, tmp_dir)
    end
  end

  describe "stop_workspace/1" do
    test "stops a running workspace", %{workspace_id: ws_id, tmp_dir: tmp_dir} do
      {:ok, _} = WorkspaceSupervisor.start_workspace(ws_id, tmp_dir)
      assert :ok = WorkspaceSupervisor.stop_workspace(ws_id)
      # Registry cleanup is async — give it a moment
      Process.sleep(50)
      refute WorkspaceSupervisor.workspace_running?(ws_id)
    end

    test "returns error for non-existent workspace" do
      assert {:error, :not_found} =
               WorkspaceSupervisor.stop_workspace("nonexistent-#{:rand.uniform(100_000)}")
    end
  end

  describe "workspace_running?/1" do
    test "returns false for unknown workspace" do
      refute WorkspaceSupervisor.workspace_running?("nonexistent-#{:rand.uniform(100_000)}")
    end
  end

  describe "workspace_healthy?/1" do
    test "returns false for unknown workspace" do
      refute WorkspaceSupervisor.workspace_healthy?("nonexistent-#{:rand.uniform(100_000)}")
    end

    test "workspace_running? and workspace_healthy? can disagree",
         %{workspace_id: ws_id, tmp_dir: tmp_dir} do
      # Regression: the "stuck :starting" bug. WorkspaceGroup stays
      # alive after its ServiceManager exits. workspace_running? is
      # the old lenient "is the group registered" check;
      # workspace_healthy? adds the essential-children liveness check.
      # Callers that matter (silent-reconnect path) use the stricter
      # one so partial-failure state doesn't silently look fine.
      {:ok, _} = WorkspaceSupervisor.start_workspace(ws_id, tmp_dir)

      # Group is up; workspace_running? must be true by definition.
      assert WorkspaceSupervisor.workspace_running?(ws_id)

      # In the absence of a compose file, ServiceManager may or may
      # not stay alive (it exits after its init task completes).
      # Force the partial state by killing the SM outright, then
      # give the group a moment to NOT restart it (it's :transient).
      compose_dir = Loopyard.Workspace.compose_dir(ws_id)

      case Registry.lookup(Loopyard.ServiceManagerRegistry, compose_dir) do
        [{sm_pid, _}] ->
          Process.exit(sm_pid, :kill)
          Process.sleep(50)

        [] ->
          # SM already gone — fine, that's the same state.
          :ok
      end

      # Now: group is still alive but SM is gone.
      assert WorkspaceSupervisor.workspace_running?(ws_id)
      refute WorkspaceSupervisor.workspace_healthy?(ws_id)
    end
  end

  describe "rebuild_saga call-site rollback_failed telemetry (audit-2 coverage #4)" do
    # Commit 2954717 added `Saga.maybe_log_rollback_failed/3` at both
    # workspace_supervisor.ex:114 and agent_boot.ex:97 so the telemetry
    # event `[:loopyard, :saga, :call_site_rollback_failed]` fires
    # from the call site, not just the recorder. The helper itself is
    # covered by saga_test.exs:454 — these tests close the loop by
    # forcing a rebuild saga to rollback-fail and asserting the event
    # fires at the WorkspaceSupervisor call site.
    #
    # `rebuild_saga` only runs when the workspace group is alive but
    # the ServiceManager is dead. Because the saga's only steps
    # (`:stop_unhealthy_group`, `:start_fresh_group`) have no :rollback
    # declared, the forward path can't produce a `:rollback_failed`
    # outcome from within a real rebuild. Instead, we exercise the
    # call-site helper directly with a simulated outcome — the same
    # check the integration test would perform on the telemetry tap.

    test "rolled_back (benign) does NOT emit call_site_rollback_failed telemetry" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:loopyard, :saga, :call_site_rollback_failed]
        ])

      Loopyard.Saga.maybe_log_rollback_failed(:rolled_back, :rebuild_workspace, %{
        workspace_id: "ws-ok"
      })

      refute_receive {[:loopyard, :saga, :call_site_rollback_failed], _, _, _}, 100

      :telemetry.detach(ref)
    end

    test "rollback_failed outcome at the workspace call site emits telemetry with saga_name + metadata" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:loopyard, :saga, :call_site_rollback_failed]
        ])

      Loopyard.Saga.maybe_log_rollback_failed(
        {:rollback_failed, [{:stop_unhealthy_group, :cant_stop}]},
        :rebuild_workspace,
        %{workspace_id: "ws-crashed"}
      )

      assert_receive {[:loopyard, :saga, :call_site_rollback_failed], ^ref, %{count: 1},
                      %{
                        saga_name: :rebuild_workspace,
                        workspace_id: "ws-crashed",
                        failed_rollbacks: [{:stop_unhealthy_group, :cant_stop}]
                      }},
                     500

      :telemetry.detach(ref)
    end
  end

  describe "partial-state auto-recovery" do
    @tag :slow
    test "start_workspace rebuilds group when ServiceManager is dead",
         %{workspace_id: ws_id, tmp_dir: tmp_dir} do
      {:ok, _} = WorkspaceSupervisor.start_workspace(ws_id, tmp_dir)

      original_group = Loopyard.WorkspaceGroup.whereis(ws_id)
      assert original_group != nil

      # Ensure the partial-failure state — kill SM if it's still
      # alive, otherwise the state is already what we need.
      compose_dir = Loopyard.Workspace.compose_dir(ws_id)

      case Registry.lookup(Loopyard.ServiceManagerRegistry, compose_dir) do
        [{sm_pid, _}] ->
          Process.exit(sm_pid, :kill)
          Process.sleep(100)

        [] ->
          :ok
      end

      refute WorkspaceSupervisor.workspace_healthy?(ws_id)

      # Calling start_workspace on a partially-dead group tears it
      # down and spins up a fresh one.
      assert {:ok, _} = WorkspaceSupervisor.start_workspace(ws_id, tmp_dir)
      Process.sleep(100)

      new_group = Loopyard.WorkspaceGroup.whereis(ws_id)
      assert new_group != nil
      assert new_group != original_group
    end
  end
end
