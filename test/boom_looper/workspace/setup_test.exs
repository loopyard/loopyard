defmodule BoomLooper.Workspace.SetupTest do
  use ExUnit.Case, async: false

  alias BoomLooper.Workspace.Setup
  alias BoomLooper.WorkspaceRegistry
  alias BoomLooper.Workspace

  describe "initial_setup_field/0" do
    test "starts at :pending with zero attempts and no error" do
      f = Setup.initial_setup_field()
      assert f.phase == :pending
      assert f.attempts == 0
      assert f.error == nil
    end
  end

  describe "ready_setup_field/0" do
    test "is :ready (used to backfill legacy workspaces)" do
      f = Setup.ready_setup_field()
      assert f.phase == :ready
      assert f.error == nil
    end
  end

  describe "Workspace.ready?/1" do
    test "true for :ready" do
      assert Workspace.ready?(%{setup: %{phase: :ready}})
    end

    test "false for any non-ready phase" do
      refute Workspace.ready?(%{setup: %{phase: :pending}})
      refute Workspace.ready?(%{setup: %{phase: :running}})
      refute Workspace.ready?(%{setup: %{phase: :seeding}})
      refute Workspace.ready?(%{setup: %{phase: :failed}})
    end

    test "true for legacy maps without setup field" do
      # Pre-feature workspaces had no :setup field; treat as ready so the
      # UI doesn't show "Setting up…" for restored workspaces forever.
      assert Workspace.ready?(%{id: "abc"})
    end
  end

  describe "recover_on_boot/0" do
    setup do
      # Insert a fake workspace at :running. recover_on_boot should
      # transition it to :failed with :interrupted_by_restart.
      ws_id = "test-recover-#{:erlang.unique_integer([:positive])}"

      ws = %{
        id: ws_id,
        project_id: "fake",
        name: "main",
        setup: %{
          phase: :running,
          attempts: 1,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          error: nil
        }
      }

      :ets.insert(:workspace_registry, {ws_id, ws})
      on_exit(fn -> :ets.delete(:workspace_registry, ws_id) end)
      %{ws_id: ws_id}
    end

    test "transitions :running workspaces to :failed with interrupted_by_restart", %{ws_id: ws_id} do
      assert Setup.recover_on_boot() >= 1

      ws = WorkspaceRegistry.get_workspace(ws_id)
      assert ws.setup.phase == :failed
      assert ws.setup.error.code == :interrupted_by_restart
      assert ws.setup.error.action =~ "Retry"
    end

    test "leaves :ready workspaces alone" do
      ws_id = "test-ready-#{:erlang.unique_integer([:positive])}"

      ws = %{
        id: ws_id,
        project_id: "fake",
        name: "main",
        setup: Setup.ready_setup_field()
      }

      :ets.insert(:workspace_registry, {ws_id, ws})
      on_exit(fn -> :ets.delete(:workspace_registry, ws_id) end)

      Setup.recover_on_boot()

      ws_after = WorkspaceRegistry.get_workspace(ws_id)
      assert ws_after.setup.phase == :ready
    end
  end

  describe "events publisher" do
    test "subscribe + publish round-trip per workspace" do
      ws_id = "test-evt-#{:erlang.unique_integer([:positive])}"
      :ok = BoomLooper.Events.WorkspaceSetup.subscribe(ws_id)

      event = %BoomLooper.Events.WorkspaceSetup.Started{
        workspace_id: ws_id,
        project_id: "p",
        attempt: 1,
        started_at: DateTime.utc_now()
      }

      BoomLooper.Events.WorkspaceSetup.publish(event)

      assert_receive %BoomLooper.Events.WorkspaceSetup.Started{workspace_id: ^ws_id}, 500
    end

    test "global topic also receives the event" do
      :ok = BoomLooper.Events.WorkspaceSetup.subscribe_global()
      ws_id = "test-evt-global-#{:erlang.unique_integer([:positive])}"

      event = %BoomLooper.Events.WorkspaceSetup.Completed{
        workspace_id: ws_id,
        total_duration_ms: 100,
        finished_at: DateTime.utc_now()
      }

      BoomLooper.Events.WorkspaceSetup.publish(event)

      assert_receive %BoomLooper.Events.WorkspaceSetup.Completed{workspace_id: ^ws_id}, 500
    end
  end
end
