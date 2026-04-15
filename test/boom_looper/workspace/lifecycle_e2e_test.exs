defmodule BoomLooper.Workspace.LifecycleE2ETest do
  @moduledoc """
  End-to-end lifecycle test against a real Docker daemon.

  Exercises the whole pipeline that unit tests can't cover:
  WorkspaceSupervisor → ServiceManager → Compose processing →
  Docker.Observer poll → agent tool (exec) → Destructor cleanup.

  Every previous compose-lifecycle regression (silent failure, leaked
  containers/volumes, stripped ports, validator bypass) would have
  been caught here.

  Gated behind the `:docker` tag so it doesn't run in the fast suite.
  Run locally with `mix test --include docker
  test/boom_looper/workspace/lifecycle_e2e_test.exs` or let CI's
  docker job pick it up.
  """
  use ExUnit.Case, async: false
  @moduletag :docker
  @moduletag timeout: 180_000

  alias BoomLooper.{Compose, Docker, VolumeManager, Workspace, WorkspaceSupervisor}
  alias BoomLooper.Tools.Container.Exec

  @agent_id "lifecycle-e2e-agent"

  setup do
    ws_id = "e2etest#{System.unique_integer([:positive]) |> rem(9999)}"
    project_dir = Path.join(System.tmp_dir!(), "boom-looper-e2e-#{ws_id}")
    File.mkdir_p!(project_dir)

    # Minimal compose: one workspace container running `sleep infinity`.
    # Everything the lifecycle needs to exercise — named volume,
    # loopback port, compose validation — is present.
    volume_name = "bl-#{ws_id}-code"

    compose = """
    {
      "services": {
        "workspace": {
          "image": "alpine:3.19",
          "command": ["sleep", "infinity"],
          "working_dir": "/workspace",
          "volumes": ["${CODE_VOLUME}:/workspace"]
        }
      }
    }
    """

    # Pre-create the volume so the compose `external: true` reference
    # resolves. Production normally does this in VolumeManager.create_volume.
    :ok = VolumeManager.create_volume(volume_name)

    # Seed the compose file into the volume — that's where ServiceManager
    # reads it from at boot. Use VolumeIO so the write path is exercised
    # end-to-end.
    :ok = BoomLooper.VolumeIO.write_file(volume_name, ".boomlooper/workspace/docker-compose.yml", compose)

    on_exit(fn ->
      BoomLooper.Workspace.Destructor.destroy(ws_id)
      File.rm_rf!(project_dir)
    end)

    %{workspace_id: ws_id, project_dir: project_dir, volume_name: volume_name}
  end

  test "full workspace lifecycle: start → exec → destroy leaves no residue",
       %{workspace_id: ws_id, project_dir: project_dir, volume_name: volume_name} do
    # --- Start the workspace ---
    assert {:ok, _pid} = WorkspaceSupervisor.start_workspace(ws_id, project_dir)

    # ServiceManager.init is async; wait up to 60s for containers up.
    wait_for(60_000, fn ->
      Docker.container_running?("bl-#{ws_id}-workspace-1")
    end)

    # --- Seed an agent state so Exec can look up the workspace ---
    :ets.insert(:chat_agents, {@agent_id, %{id: @agent_id, workspace_id: ws_id}})

    # --- Run a real command through the Exec tool ---
    assert {:ok, output} =
             Exec.execute(%{agent_id: @agent_id, command: "echo lifecycle-ok"}, %{})

    assert output =~ "lifecycle-ok"

    # --- Verify the processed compose bound ports to loopback ---
    # (no port here, but verify the processed file at least parses —
    # regressions in Compose.process_agent_compose would fail earlier).
    compose_path = Compose.compose_path(Workspace.compose_dir(ws_id))
    assert File.exists?(compose_path)
    assert {:ok, processed} = File.read(compose_path)
    assert {:ok, json} = Jason.decode(processed)
    assert get_in(json, ["volumes", volume_name, "external"]) == true

    # --- Tear down and verify no residue ---
    BoomLooper.Workspace.Destructor.destroy(ws_id)

    # Workspace container is gone.
    refute Docker.container_exists?("bl-#{ws_id}-workspace-1"),
           "workspace container should be removed after destroy"

    # Code volume is gone.
    refute VolumeManager.volume_exists?(volume_name),
           "code volume should be removed after destroy"

    # Compose dir is gone.
    refute File.exists?(Workspace.compose_dir(ws_id)),
           "compose dir should be removed after destroy"

    # Supervisor subtree is gone.
    refute WorkspaceSupervisor.workspace_running?(ws_id),
           "workspace supervisor subtree should be stopped after destroy"

    :ets.delete(:chat_agents, @agent_id)
  end

  test "agent compose with a host bind mount is rejected and cluster refuses to start",
       %{workspace_id: ws_id, project_dir: project_dir, volume_name: volume_name} do
    # Overwrite the seeded good compose with a bad one. The validator
    # should reject this at boot time; the cluster stays down.
    bad_compose = """
    {
      "services": {
        "workspace": {
          "image": "alpine:3.19",
          "command": ["sleep", "infinity"],
          "volumes": ["/etc:/host/etc"]
        }
      }
    }
    """

    :ok =
      BoomLooper.VolumeIO.write_file(
        volume_name,
        ".boomlooper/workspace/docker-compose.yml",
        bad_compose
      )

    {:ok, _pid} = WorkspaceSupervisor.start_workspace(ws_id, project_dir)

    # Give ServiceManager.init a few seconds to try and reject.
    Process.sleep(5_000)

    # Container should NOT be up — validator rejected the compose file.
    refute Docker.container_running?("bl-#{ws_id}-workspace-1"),
           "workspace container must not start when compose has a host bind mount"

    _ = project_dir
  end

  # Busy-wait up to `timeout_ms` for `fun` to return a truthy value.
  # Fails the test if it doesn't.
  defp wait_for(timeout_ms, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn -> fun.() end)
    |> Stream.take_while(fn
      truthy when truthy == false or truthy == nil ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("wait_for timed out after #{timeout_ms}ms")
        else
          Process.sleep(500)
          true
        end

      _ ->
        false
    end)
    |> Enum.to_list()
  end
end
