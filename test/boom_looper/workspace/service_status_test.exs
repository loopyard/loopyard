defmodule BoomLooper.Workspace.ServiceStatusTest do
  @moduledoc """
  Tests for reliable service status display.

  The key requirement: services should be shown based on workspace config,
  NOT dependent on PubSub timing. Running state comes from Docker.
  """
  use ExUnit.Case

  alias BoomLooper.Workspace
  alias BoomLooper.Workspace.ServiceStatus

  describe "list_defined_services/1" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-svc-status-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    test "returns empty list when no workspace config", %{tmp_dir: tmp_dir} do
      assert ServiceStatus.list_defined_services(tmp_dir) == []
    end

    test "returns stock services from workspace config", %{tmp_dir: tmp_dir} do
      ws = %Workspace{
        name: "Test",
        services: [
          %{name: "postgres", image: "postgres:16", env: %{}, volumes: [], ports: %{}},
          %{name: "redis", image: "redis:7-alpine", env: %{}, volumes: [], ports: %{}}
        ]
      }
      Workspace.save(tmp_dir, ws)

      services = ServiceStatus.list_defined_services(tmp_dir)

      assert length(services) == 2
      names = Enum.map(services, & &1.name)
      assert "postgres" in names
      assert "redis" in names
    end

    test "returns processes from workspace config", %{tmp_dir: tmp_dir} do
      ws = %Workspace{
        name: "Test",
        dockerfile: "FROM ruby:3.2",
        processes: [
          %{name: "dev", command: "bin/rails server -p 3000", ports: ["3000"]}
        ]
      }
      Workspace.save(tmp_dir, ws)

      services = ServiceStatus.list_defined_services(tmp_dir)

      assert length(services) == 1
      dev = hd(services)
      assert dev.name == "dev"
      assert dev.type == :process
      assert dev.command == "bin/rails server -p 3000"
    end

    test "includes both services and processes", %{tmp_dir: tmp_dir} do
      ws = %Workspace{
        name: "Test",
        dockerfile: "FROM ruby:3.2",
        services: [
          %{name: "postgres", image: "postgres:16", env: %{}, volumes: [], ports: %{}}
        ],
        processes: [
          %{name: "dev", command: "bin/rails server", ports: ["3000"]}
        ]
      }
      Workspace.save(tmp_dir, ws)

      services = ServiceStatus.list_defined_services(tmp_dir)

      assert length(services) == 2
      types = Enum.map(services, & &1.type)
      assert :stock in types
      assert :process in types
    end

    test "services have type :stock", %{tmp_dir: tmp_dir} do
      ws = %Workspace{
        name: "Test",
        services: [
          %{name: "postgres", image: "postgres:16", env: %{}, volumes: [], ports: %{}}
        ]
      }
      Workspace.save(tmp_dir, ws)

      [service] = ServiceStatus.list_defined_services(tmp_dir)
      assert service.type == :stock
      assert service.image == "postgres:16"
    end
  end

  describe "get_running_state/2" do
    @describetag :docker

    test "returns running: false for containers that don't exist" do
      state = ServiceStatus.get_running_state("nonexistent-workspace-id-12345", "postgres")
      assert state.running == false
      assert state.container == nil
    end
  end

  describe "merge_status/2" do
    test "merges defined services with running state" do
      defined = [
        %{name: "postgres", type: :stock, image: "postgres:16"},
        %{name: "dev", type: :process, command: "bin/rails server"}
      ]

      running = %{
        "postgres" => %{running: true, container: "bl-abc-postgres-1", ports: %{}, health: :healthy},
        "dev" => %{running: false, container: nil, ports: %{}, health: nil}
      }

      merged = ServiceStatus.merge_status(defined, running)

      assert length(merged) == 2

      pg = Enum.find(merged, & &1.name == "postgres")
      assert pg.running == true
      assert pg.container == "bl-abc-postgres-1"
      assert pg.health == :healthy

      dev = Enum.find(merged, & &1.name == "dev")
      assert dev.running == false
      assert dev.container == nil
    end

    test "preserves service metadata from definition" do
      defined = [%{name: "postgres", type: :stock, image: "postgres:16"}]
      running = %{"postgres" => %{running: true, container: "pg-1", ports: %{"5432" => "5433"}, health: :healthy}}

      [merged] = ServiceStatus.merge_status(defined, running)

      assert merged.name == "postgres"
      assert merged.type == :stock
      assert merged.image == "postgres:16"
      assert merged.running == true
      assert merged.ports == %{"5432" => "5433"}
    end
  end

  describe "for_workspace/1 - full integration" do
    @describetag :docker

    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-svc-full-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    test "returns complete service status for workspace", %{tmp_dir: tmp_dir} do
      ws = %Workspace{
        name: "Integration Test",
        services: [
          %{name: "postgres", image: "postgres:16", env: %{}, volumes: [], ports: %{}}
        ]
      }
      Workspace.save(tmp_dir, ws)

      # Without Docker running, services should show as defined but not running
      services = ServiceStatus.for_workspace(tmp_dir)

      assert length(services) == 1
      [pg] = services
      assert pg.name == "postgres"
      assert pg.type == :stock
      assert pg.image == "postgres:16"
      assert pg.running == false
    end
  end
end
