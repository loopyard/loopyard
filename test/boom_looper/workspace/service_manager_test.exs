defmodule BoomLooper.Workspace.ServiceManagerTest do
  use ExUnit.Case

  alias BoomLooper.Workspace
  alias BoomLooper.Workspace.ServiceManager

  describe "naming" do
    test "service_container_name" do
      assert ServiceManager.service_container_name("abcd", "postgres") == "boom-looper-svc-abcd-postgres"
    end

    test "service_volume_name" do
      assert ServiceManager.service_volume_name("abcd", "postgres") == "boom-looper-svc-abcd-postgres-data"
    end
  end

  describe "start_services/1 with no config" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-svc-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    test "returns ok with empty list when no workspace config", %{tmp_dir: tmp_dir} do
      BoomLooper.TestHelpers.ensure_branch(tmp_dir)
      assert {:ok, []} = ServiceManager.start_services(tmp_dir)
    end
  end

  describe "service_status/1" do
    test "returns empty list for unknown workspace" do
      assert {:ok, []} = ServiceManager.service_status("/nonexistent/path/#{:rand.uniform(100_000)}")
    end
  end

  describe "service_exec/3" do
    @describetag :docker

    test "returns error for non-existent service container" do
      assert {:error, msg} = ServiceManager.service_exec("/tmp/nonexistent-#{:rand.uniform(100_000)}", "postgres", "SELECT 1")
      assert msg =~ "Failed to exec in postgres"
    end
  end

  describe "subscribe/0" do
    test "subscribes to service updates" do
      assert :ok = ServiceManager.subscribe()
    end
  end

  describe "PubSub broadcasts" do
    @describetag :docker

    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-svc-pubsub-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)

      # Write a workspace config with a stock service
      ws = %Workspace{
        name: "PubSub Test",
        services: [
          %{name: "redis", image: "redis:7-alpine", env: %{}, volumes: [], ports: %{}}
        ]
      }

      Workspace.save(tmp_dir, ws)

      on_exit(fn ->
        ServiceManager.stop_services(tmp_dir)
        File.rm_rf!(tmp_dir)
      end)

      %{tmp_dir: tmp_dir}
    end

    test "start_services broadcasts services_updated", %{tmp_dir: tmp_dir} do
      # Subscribe BEFORE starting services
      ServiceManager.subscribe()

      ServiceManager.start_services(tmp_dir)

      assert_receive {:services_updated, ^tmp_dir, statuses}, 2000
      assert is_list(statuses)
      assert length(statuses) >= 1
      redis = Enum.find(statuses, &(&1.name == "redis"))
      assert redis != nil
      assert redis.type == :stock
    end

    test "start_services broadcasts include ports in status", %{tmp_dir: tmp_dir} do
      ServiceManager.subscribe()
      ServiceManager.start_services(tmp_dir)

      assert_receive {:services_updated, ^tmp_dir, statuses}, 2000
      redis = Enum.find(statuses, &(&1.name == "redis"))
      assert Map.has_key?(redis, :ports)
    end
  end

  describe "workspace container with processes" do
    @describetag :docker

    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-svc-ws-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)

      ws = %Workspace{
        name: "Process Test",
        services: [
          %{name: "postgres", image: "postgres:16", env: %{}, volumes: [], ports: %{}}
        ],
        processes: [
          %{name: "web", command: "bin/rails server -p 3000", ports: ["3000:3000"]},
          %{name: "css", command: "bin/rails tailwindcss:watch"}
        ]
      }

      Workspace.save(tmp_dir, ws)

      on_exit(fn ->
        ServiceManager.stop_services(tmp_dir)
        File.rm_rf!(tmp_dir)
      end)

      %{tmp_dir: tmp_dir}
    end

    test "broadcasts processes as separate status entries", %{tmp_dir: tmp_dir} do
      ServiceManager.subscribe()
      ServiceManager.start_services(tmp_dir)

      assert_receive {:services_updated, ^tmp_dir, statuses}, 2000

      # Should have stock service + processes
      stock = Enum.filter(statuses, &(&1.type == :stock))
      procs = Enum.filter(statuses, &(&1.type == :process))

      assert length(stock) == 1
      assert hd(stock).name == "postgres"

      assert length(procs) == 2
      proc_names = Enum.map(procs, & &1.name)
      assert "web" in proc_names
      assert "css" in proc_names

      web = Enum.find(procs, &(&1.name == "web"))
      assert web.command == "bin/rails server -p 3000"
      # All processes share the workspace container
      assert web.container =~ "boom-looper-ws-"
    end
  end

  # Docker integration tests
  describe "full service lifecycle" do
    @describetag :docker

    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-svc-test-#{:rand.uniform(100_000)}")
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
