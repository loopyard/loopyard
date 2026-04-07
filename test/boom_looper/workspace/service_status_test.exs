defmodule BoomLooper.Workspace.ServiceStatusTest do
  @moduledoc """
  Tests for reliable service status display.

  The key requirement: services should be shown based on docker-compose.yml,
  NOT dependent on PubSub timing. Running state comes from Docker.
  """
  use ExUnit.Case

  alias BoomLooper.Workspace.ServiceStatus

  describe "list_defined_services/1" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-svc-status-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    test "returns empty list when no docker-compose.yml", %{tmp_dir: tmp_dir} do
      assert ServiceStatus.list_defined_services(tmp_dir) == []
    end

    test "returns stock services from docker-compose.yml", %{tmp_dir: tmp_dir} do
      write_compose(tmp_dir, """
      services:
        postgres:
          image: postgres:16
        redis:
          image: redis:7-alpine
      """)

      services = ServiceStatus.list_defined_services(tmp_dir)

      assert length(services) == 2
      names = Enum.map(services, & &1.name)
      assert "postgres" in names
      assert "redis" in names
    end

    test "returns processes from docker-compose.yml", %{tmp_dir: tmp_dir} do
      write_compose(tmp_dir, """
      services:
        workspace:
          build: .
        dev:
          build: .
          command: bin/rails server -p 3000
      """)

      services = ServiceStatus.list_defined_services(tmp_dir)

      # workspace is excluded
      assert length(services) == 1
      dev = hd(services)
      assert dev.name == "dev"
      assert dev.type == :process
    end

    test "includes both stock services and processes", %{tmp_dir: tmp_dir} do
      write_compose(tmp_dir, """
      services:
        workspace:
          build: .
        postgres:
          image: postgres:16
        dev:
          build: .
          command: bin/rails server
      """)

      services = ServiceStatus.list_defined_services(tmp_dir)

      assert length(services) == 2
      types = Enum.map(services, & &1.type)
      assert :stock in types
      assert :process in types
    end

    test "infers type based on service name", %{tmp_dir: tmp_dir} do
      write_compose(tmp_dir, """
      services:
        postgres:
          image: postgres:16
        myapp:
          build: .
      """)

      services = ServiceStatus.list_defined_services(tmp_dir)

      pg = Enum.find(services, & &1.name == "postgres")
      app = Enum.find(services, & &1.name == "myapp")
      assert pg.type == :stock
      assert app.type == :process
    end
  end

  describe "get_running_state/2" do
    @describetag :docker

    test "returns status: :stopped for containers that don't exist" do
      state = ServiceStatus.get_running_state("nonexistent-workspace-id-12345", "postgres")
      assert state.status == :stopped
      assert state.container == nil
    end
  end

  describe "merge_status/2" do
    alias BoomLooper.Workspace.ServiceStatus.Service

    test "merges defined services with running state" do
      defined = [
        %Service{name: "postgres", type: :stock, status: :stopped},
        %Service{name: "dev", type: :process, status: :stopped}
      ]

      running = %{
        "postgres" => %{status: :running, container: "bl-abc-postgres-1", ports: %{}, exit_info: nil},
        "dev" => %{status: :stopped, container: nil, ports: %{}, exit_info: nil}
      }

      merged = ServiceStatus.merge_status(defined, running)

      assert length(merged) == 2

      pg = Enum.find(merged, &(&1.name == "postgres"))
      assert pg.status == :running
      assert pg.container == "bl-abc-postgres-1"

      dev = Enum.find(merged, &(&1.name == "dev"))
      assert dev.status == :stopped
      assert dev.container == nil
    end

    test "preserves service metadata from definition" do
      defined = [%Service{name: "postgres", type: :stock, status: :stopped}]
      running = %{"postgres" => %{status: :running, container: "pg-1", ports: %{"5432" => "5433"}, exit_info: nil}}

      [merged] = ServiceStatus.merge_status(defined, running)

      assert merged.name == "postgres"
      assert merged.type == :stock
      assert merged.status == :running
      assert merged.ports == %{"5432" => "5433"}
    end

    test "result is a Service struct, not a plain map" do
      defined = [%Service{name: "x", type: :stock, status: :stopped}]
      running = %{"x" => %{status: :running, container: "x-1", ports: %{}, exit_info: nil}}

      [merged] = ServiceStatus.merge_status(defined, running)

      assert %Service{} = merged
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
      write_compose(tmp_dir, """
      services:
        postgres:
          image: postgres:16
      """)

      # Without Docker running, services should show as defined but not running
      services = ServiceStatus.for_workspace(tmp_dir)

      assert length(services) == 1
      [pg] = services
      assert pg.name == "postgres"
      assert pg.type == :stock
      assert pg.running == false
    end
  end

  # Helper to write docker-compose.yml in the expected location
  defp write_compose(tmp_dir, content) do
    compose_dir = Path.join([tmp_dir, ".boomlooper", "workspace"])
    File.mkdir_p!(compose_dir)
    File.write!(Path.join(compose_dir, "docker-compose.yml"), content)
  end
end
