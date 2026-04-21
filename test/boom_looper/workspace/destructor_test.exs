defmodule BoomLooper.Workspace.DestructorTest do
  @moduledoc """
  Destructor is the single cleanup path for workspace deletion. It
  must:

    * Run every teardown step — including when individual steps fail.
    * Be idempotent — re-running on a gone workspace is safe.
    * Never crash — a raise would leave a half-destroyed workspace.

  Docker-backed steps (compose down, volume rm) are exercised in the
  `:docker` tests; this file proves the orchestration, ETS cleanup,
  and failure tolerance without needing a real daemon.
  """
  use ExUnit.Case, async: false

  # Destructor runs compose-down + volume-rm; even in the no-daemon
  # path the docker CLI shellout can take a second or two to fail.
  @moduletag timeout: 10_000

  alias BoomLooper.Workspace.Destructor
  alias BoomLooper.WorkspaceRegistry

  @workspaces_table :workspace_registry

  setup do
    # Seed a fake workspace entry so destroy/1 takes the "known
    # workspace" branch. Destructor will fail soft on every Docker step
    # (no daemon running in test env), which is what we want to verify.
    ws_id = "destructor-test-#{:rand.uniform(1_000_000)}"

    workspace = %{
      id: ws_id,
      project_id: "project-does-not-exist",
      name: "test",
      path: "/tmp/destructor-test-#{ws_id}",
      is_main: false,
      status: :stopped,
      added_at: DateTime.utc_now()
    }

    :ets.insert(@workspaces_table, {ws_id, workspace})
    on_exit(fn -> :ets.delete(@workspaces_table, ws_id) end)

    %{workspace_id: ws_id}
  end

  describe "destroy/1" do
    test "clears the workspace's ETS entry even if Docker steps fail",
         %{workspace_id: ws_id} do
      assert WorkspaceRegistry.get_workspace(ws_id) != nil
      assert :ok = Destructor.destroy(ws_id)
      assert WorkspaceRegistry.get_workspace(ws_id) == nil
    end

    test "never raises on unknown workspace_id (sweep path)" do
      assert :ok = Destructor.destroy("does-not-exist-#{:rand.uniform(1_000_000)}")
    end

    test "is idempotent — running twice is safe",
         %{workspace_id: ws_id} do
      assert :ok = Destructor.destroy(ws_id)
      assert :ok = Destructor.destroy(ws_id)
      assert WorkspaceRegistry.get_workspace(ws_id) == nil
    end

    test "removes the compose dir on the host if present",
         %{workspace_id: ws_id} do
      compose_dir = BoomLooper.Workspace.compose_dir(ws_id)
      File.mkdir_p!(Path.join(compose_dir, ".boomlooper/workspace"))
      File.write!(Path.join(compose_dir, "marker"), "test")
      assert File.exists?(Path.join(compose_dir, "marker"))

      Destructor.destroy(ws_id)

      refute File.exists?(compose_dir),
             "compose dir #{compose_dir} should be gone after destroy"
    end

    test "stops agents belonging to the workspace",
         %{workspace_id: ws_id} do
      # Insert a fake agent entry that matches the workspace. Destructor
      # will attempt to stop it; no real ChatAgent process exists so
      # stop_agent catches the :noproc exit internally. What we verify
      # is that the destroy completes cleanly — not that the agent
      # process shuts down (there isn't one).
      agent_id = "agent-destructor-test-#{:rand.uniform(1_000_000)}"

      :ets.insert(
        :chat_agents,
        {agent_id,
         %{
           id: agent_id,
           workspace_id: ws_id,
           name: "test",
           status: :idle,
           working_dir: "/tmp",
           messages: []
         }}
      )

      on_exit(fn -> :ets.delete(:chat_agents, agent_id) end)

      assert :ok = Destructor.destroy(ws_id)
    end
  end
end
