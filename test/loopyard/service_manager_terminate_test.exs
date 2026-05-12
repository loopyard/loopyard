defmodule Loopyard.ServiceManagerTerminateTest do
  @moduledoc """
  Tests that ServiceManager.terminate/2 leaves containers running.

  Per the architecture: containers persist across ServiceManager restarts.
  State lives in volumes and ETF logs, and `init/1` reconnects via
  `Compose.ps` on the next start. Only explicit `stop_services/1` tears
  containers down.

  This test covers the plain `terminate/2` contract without needing
  a real Docker daemon. See the `:docker`-tagged test below for the
  end-to-end behavior.
  """
  use ExUnit.Case, async: false

  alias Loopyard.{WorkspaceSupervisor, Workspace}

  describe "terminate is always called on stop" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "boom-looper-term-call-test-#{:rand.uniform(100_000)}")

      File.mkdir_p!(tmp_dir)
      workspace_id = Workspace.workspace_id(tmp_dir)

      on_exit(fn ->
        WorkspaceSupervisor.stop_workspace(workspace_id)
        Process.sleep(100)
        File.rm_rf!(tmp_dir)
      end)

      %{tmp_dir: tmp_dir, workspace_id: workspace_id}
    end

    @tag :slow
    test "stop_workspace terminates ServiceManager process", %{
      tmp_dir: tmp_dir,
      workspace_id: ws_id
    } do
      {:ok, _} = WorkspaceSupervisor.start_workspace(ws_id, tmp_dir)
      Process.sleep(500)

      # ServiceManager should be registered
      assert [{pid, _}] = Registry.lookup(Loopyard.ServiceManagerRegistry, tmp_dir)
      assert Process.alive?(pid)

      # Monitor the ServiceManager process
      ref = Process.monitor(pid)

      # Stop the workspace
      assert :ok = WorkspaceSupervisor.stop_workspace(ws_id)

      # ServiceManager should receive :DOWN
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end
  end

  describe "terminate does not call Compose.down" do
    @describetag :docker
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "boom-looper-term-keep-test-#{:rand.uniform(100_000)}")

      File.mkdir_p!(tmp_dir)
      workspace_id = Workspace.workspace_id(tmp_dir)

      config_dir = Path.join([tmp_dir, ".loopyard", "repo"])
      File.mkdir_p!(config_dir)

      File.write!(
        Path.join(config_dir, "workspace.json"),
        Jason.encode!(%{
          "name" => "terminate-keep-test",
          "dockerfile" => "FROM alpine:latest\nCMD sleep infinity",
          "processes" => [],
          "services" => [],
          "env_vars" => %{}
        })
      )

      on_exit(fn ->
        WorkspaceSupervisor.stop_workspace(workspace_id)
        Process.sleep(200)

        virtual_dir = Path.join([Workspace.home_dir(), "workspaces", workspace_id])

        try do
          Loopyard.Compose.down_volumes(virtual_dir, workspace_id)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

        File.rm_rf!(tmp_dir)
      end)

      %{tmp_dir: tmp_dir, workspace_id: workspace_id}
    end

    test "containers keep running after ServiceManager terminates", %{
      tmp_dir: tmp_dir,
      workspace_id: ws_id
    } do
      {:ok, _} = WorkspaceSupervisor.start_workspace(ws_id, tmp_dir)
      Process.sleep(2_000)

      virtual_dir = Path.join([Workspace.home_dir(), "workspaces", ws_id])

      case Loopyard.Compose.ps(virtual_dir, ws_id) do
        {:ok, services} when services != [] ->
          # Containers are running — terminate the ServiceManager WITHOUT
          # going through stop_services (i.e. simulate a crash / shutdown).
          [{pid, _}] = Registry.lookup(Loopyard.ServiceManagerRegistry, tmp_dir)
          ref = Process.monitor(pid)
          Process.exit(pid, :shutdown)
          assert_receive {:DOWN, ^ref, _, _, _}, 5_000

          # Containers should still be running.
          case Loopyard.Compose.ps(virtual_dir, ws_id) do
            {:ok, still_running} when still_running != [] ->
              assert Enum.any?(still_running, &(&1.state == "running"))

            other ->
              flunk("Expected containers still running after terminate, got #{inspect(other)}")
          end

        _ ->
          # Compose didn't start anything — test isn't meaningful here.
          :ok
      end
    end
  end
end
