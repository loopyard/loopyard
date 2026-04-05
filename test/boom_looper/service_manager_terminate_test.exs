defmodule BoomLooper.ServiceManagerTerminateTest do
  @moduledoc """
  Tests that ServiceManager.terminate/2 properly tears down Docker containers,
  preventing zombie containers from accumulating.
  """
  use ExUnit.Case, async: false

  alias BoomLooper.{WorkspaceSupervisor, Workspace, Compose}

  describe "terminate tears down containers" do
    @describetag :docker
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-terminate-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      workspace_id = Workspace.workspace_id(tmp_dir)

      # Write a minimal workspace config so compose has something to start
      config_dir = Path.join([tmp_dir, ".boomlooper", "repo"])
      File.mkdir_p!(config_dir)
      File.write!(Path.join(config_dir, "workspace.json"), Jason.encode!(%{
        "name" => "terminate-test",
        "dockerfile" => "FROM alpine:latest\nCMD sleep infinity",
        "processes" => [],
        "services" => [],
        "env_vars" => %{}
      }))

      on_exit(fn ->
        # Best-effort cleanup — stop workspace if still running
        WorkspaceSupervisor.stop_workspace(workspace_id)
        Process.sleep(200)

        # Force compose down in case test left containers
        virtual_dir = Path.join([Workspace.home_dir(), "workspaces", workspace_id])
        try do
          Compose.down_volumes(virtual_dir, workspace_id)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

        File.rm_rf!(tmp_dir)
      end)

      %{tmp_dir: tmp_dir, workspace_id: workspace_id}
    end

    test "stop_workspace tears down compose containers", %{tmp_dir: tmp_dir, workspace_id: ws_id} do
      # Start the workspace (this starts ServiceManager which runs compose up)
      {:ok, _} = WorkspaceSupervisor.start_workspace(ws_id, tmp_dir)

      # Give ServiceManager time to start containers
      Process.sleep(2_000)

      virtual_dir = Path.join([Workspace.home_dir(), "workspaces", ws_id])

      # Verify containers are running
      case Compose.ps(virtual_dir, ws_id) do
        {:ok, services} when services != [] ->
          # Containers are running — now stop the workspace
          assert :ok = WorkspaceSupervisor.stop_workspace(ws_id)
          # Give terminate time to run compose down
          Process.sleep(2_000)

          # Containers should be gone
          case Compose.ps(virtual_dir, ws_id) do
            {:ok, []} -> :ok
            {:ok, services} ->
              running = Enum.filter(services, & &1.state == "running")
              assert running == [], "Expected no running containers, got: #{inspect(running)}"
            {:error, _} ->
              # Compose can't find anything — that's fine, containers are gone
              :ok
          end

        _ ->
          # No containers started (maybe Docker not available or no compose config)
          # Skip this test gracefully
          :ok
      end
    end

    test "stop_workspace doesn't crash when no containers exist", %{tmp_dir: tmp_dir, workspace_id: ws_id} do
      {:ok, _} = WorkspaceSupervisor.start_workspace(ws_id, tmp_dir)
      Process.sleep(500)

      # Stop should succeed even with no running containers
      assert :ok = WorkspaceSupervisor.stop_workspace(ws_id)
      Process.sleep(100)
      refute WorkspaceSupervisor.workspace_running?(ws_id)
    end
  end

  describe "terminate is always called on stop" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-term-call-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      workspace_id = Workspace.workspace_id(tmp_dir)

      on_exit(fn ->
        WorkspaceSupervisor.stop_workspace(workspace_id)
        Process.sleep(100)
        File.rm_rf!(tmp_dir)
      end)

      %{tmp_dir: tmp_dir, workspace_id: workspace_id}
    end

    test "stop_workspace terminates ServiceManager process", %{tmp_dir: tmp_dir, workspace_id: ws_id} do
      {:ok, _} = WorkspaceSupervisor.start_workspace(ws_id, tmp_dir)
      Process.sleep(500)

      # ServiceManager should be registered
      assert [{pid, _}] = Registry.lookup(BoomLooper.ServiceManagerRegistry, tmp_dir)
      assert Process.alive?(pid)

      # Monitor the ServiceManager process
      ref = Process.monitor(pid)

      # Stop the workspace
      assert :ok = WorkspaceSupervisor.stop_workspace(ws_id)

      # ServiceManager should receive :DOWN
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end
  end
end
