defmodule Hive.Workspace.ServiceManagerTest do
  use ExUnit.Case

  alias Hive.Workspace
  alias Hive.Workspace.ServiceManager

  describe "naming" do
    test "service_container_name" do
      assert ServiceManager.service_container_name("abcd", "postgres") == "hive-svc-abcd-postgres"
    end

    test "service_volume_name" do
      assert ServiceManager.service_volume_name("abcd", "postgres") == "hive-svc-abcd-postgres-data"
    end
  end

  describe "start_services/1 with no config" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "hive-svc-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    test "returns ok with empty list when no workspace config", %{tmp_dir: tmp_dir} do
      assert {:ok, []} = ServiceManager.start_services(tmp_dir)
    end
  end

  describe "service_status/1" do
    test "returns empty list for unknown workspace" do
      assert {:ok, []} = ServiceManager.service_status("/nonexistent/path/#{:rand.uniform(100_000)}")
    end
  end

  # Docker integration tests
  describe "full service lifecycle" do
    @describetag :docker

    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "hive-svc-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)

      ws = %Workspace{
        name: "Test Project",
        services: [
          %{
            name: "redis",
            image: "redis:7-alpine",
            env: %{},
            volumes: [],
            ports: %{}
          }
        ]
      }

      Workspace.save(tmp_dir, ws)
      workspace_id = Workspace.workspace_id(tmp_dir)

      on_exit(fn ->
        ServiceManager.stop_services(tmp_dir)
        container = ServiceManager.service_container_name(workspace_id, "redis")
        System.cmd("docker", ["rm", "-f", container], stderr_to_stdout: true)
        File.rm_rf!(tmp_dir)
      end)

      %{tmp_dir: tmp_dir, workspace_id: workspace_id}
    end

    test "starts and stops service containers", %{tmp_dir: tmp_dir} do
      assert {:ok, results} = ServiceManager.start_services(tmp_dir)
      assert length(results) == 1

      assert {:ok, statuses} = ServiceManager.service_status(tmp_dir)
      assert length(statuses) == 1
      assert hd(statuses).name == "redis"
      assert hd(statuses).running == true

      assert :ok = ServiceManager.stop_services(tmp_dir)
    end
  end
end
