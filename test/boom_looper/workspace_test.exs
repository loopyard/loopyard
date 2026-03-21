defmodule BoomLooper.WorkspaceTest do
  use ExUnit.Case

  alias BoomLooper.Workspace

  @sample_config %{
    "name" => "My Rails App",
    "dockerfile" => "FROM ruby:3.4\nRUN apt-get update",
    "services" => [
      %{
        "name" => "postgres",
        "image" => "postgis/postgis:16-3.4",
        "env" => %{"POSTGRES_PASSWORD" => "postgres"},
        "volumes" => ["pgdata:/var/lib/postgresql/data"],
        "ports" => %{"5432" => "5432"}
      }
    ],
    "processes" => [
      %{"name" => "web", "command" => "bin/rails server -b 0.0.0.0 -p 3000"},
      %{"name" => "worker", "command" => "bin/rails solid_queue:start"}
    ],
    "env_vars" => %{
      "DATABASE_URL" => "postgres://postgres:postgres@postgres:5432/myapp_dev"
    },
    "system_prompt" => "Rails 8 project with PostgreSQL"
  }

  describe "from_map/1" do
    test "parses a full config — stock services in services, processes in processes" do
      ws = Workspace.from_map(@sample_config)

      assert ws.name == "My Rails App"
      assert ws.dockerfile == "FROM ruby:3.4\nRUN apt-get update"
      # 1 stock service (postgres)
      assert length(ws.services) == 1
      postgres = hd(ws.services)
      assert postgres.name == "postgres"
      assert postgres.image == "postgis/postgis:16-3.4"
      assert postgres.env == %{"POSTGRES_PASSWORD" => "postgres"}
      # 2 processes (web, worker)
      assert length(ws.processes) == 2
      web = Enum.find(ws.processes, fn p -> p.name == "web" end)
      assert web.command == "bin/rails server -b 0.0.0.0 -p 3000"
      assert ws.env_vars["DATABASE_URL"] =~ "postgres"
      assert ws.system_prompt == "Rails 8 project with PostgreSQL"
    end

    test "handles missing optional fields" do
      ws = Workspace.from_map(%{"name" => "Minimal"})

      assert ws.name == "Minimal"
      assert ws.dockerfile == nil
      assert ws.services == []
      assert ws.processes == []
      assert ws.env_vars == %{}
      assert ws.system_prompt == nil
    end

    test "service with command but no image goes to processes" do
      ws = Workspace.from_map(%{
        "services" => [
          %{"name" => "web", "command" => "bin/rails server"},
          %{"name" => "postgres", "image" => "postgres:16"}
        ]
      })

      assert length(ws.services) == 1
      assert hd(ws.services).name == "postgres"
      assert length(ws.processes) == 1
      assert hd(ws.processes).name == "web"
      assert hd(ws.processes).command == "bin/rails server"
    end

    test "legacy processes go to processes field" do
      ws = Workspace.from_map(%{
        "services" => [%{"name" => "postgres", "image" => "postgres:16"}],
        "processes" => [%{"name" => "web", "command" => "npm start"}]
      })

      assert length(ws.services) == 1
      assert hd(ws.services).name == "postgres"
      assert length(ws.processes) == 1
      assert hd(ws.processes).name == "web"
      assert hd(ws.processes).command == "npm start"
    end

    test "duplicate names in legacy processes don't override service-defined processes" do
      ws = Workspace.from_map(%{
        "services" => [%{"name" => "web", "command" => "bin/rails server"}],
        "processes" => [%{"name" => "web", "command" => "npm start"}]
      })

      assert length(ws.processes) == 1
      assert hd(ws.processes).command == "bin/rails server"
    end
  end

  describe "to_map/1" do
    test "round-trips through from_map" do
      ws = Workspace.from_map(@sample_config)
      map = Workspace.to_map(ws)

      assert map["name"] == "My Rails App"
      assert map["dockerfile"] == "FROM ruby:3.4\nRUN apt-get update"
      # Services only has stock services
      assert length(map["services"]) == 1
      postgres = hd(map["services"])
      assert postgres["image"] == "postgis/postgis:16-3.4"
      # Processes has the dev processes
      assert length(map["processes"]) == 2
      web = Enum.find(map["processes"], fn p -> p["name"] == "web" end)
      assert web["command"] == "bin/rails server -b 0.0.0.0 -p 3000"
      assert map["env_vars"]["DATABASE_URL"] =~ "postgres"
    end

    test "round-trip from_map -> to_map -> from_map preserves the split" do
      ws1 = Workspace.from_map(@sample_config)
      ws2 = ws1 |> Workspace.to_map() |> Workspace.from_map()

      assert length(ws2.services) == 1
      assert hd(ws2.services).name == "postgres"
      assert length(ws2.processes) == 2
      names = Enum.map(ws2.processes, & &1.name)
      assert "web" in names
      assert "worker" in names
    end
  end

  describe "config_path/1" do
    test "returns path to .boomlooper/repo/workspace.json" do
      assert Workspace.config_path("/home/user/project") == "/home/user/project/.boomlooper/repo/workspace.json"
    end
  end

  describe "workspace_id/1" do
    test "returns a deterministic hex string" do
      id1 = Workspace.workspace_id("/home/user/project")
      id2 = Workspace.workspace_id("/home/user/project")
      assert id1 == id2
      assert is_binary(id1)
      assert String.length(id1) >= 4
    end

    test "differs for different paths" do
      id1 = Workspace.workspace_id("/home/user/project-a")
      id2 = Workspace.workspace_id("/home/user/project-b")
      assert id1 != id2
    end
  end

  describe "save/2 and load/1" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-ws-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    test "saves and loads workspace config", %{tmp_dir: tmp_dir} do
      ws = Workspace.from_map(@sample_config)
      assert :ok = Workspace.save(tmp_dir, ws)

      assert {:ok, loaded} = Workspace.load(tmp_dir)
      assert loaded.name == "My Rails App"
      assert length(loaded.services) == 1
      assert hd(loaded.services).image == "postgis/postgis:16-3.4"
      assert length(loaded.processes) == 2
      web = Enum.find(loaded.processes, fn p -> p.name == "web" end)
      assert web.command == "bin/rails server -b 0.0.0.0 -p 3000"
    end

    test "load returns :none when no config exists", %{tmp_dir: tmp_dir} do
      assert :none = Workspace.load(tmp_dir)
    end

    test "creates .boomlooper/repo directory if it doesn't exist", %{tmp_dir: tmp_dir} do
      ws = %Workspace{name: "Test"}
      Workspace.save(tmp_dir, ws)

      assert File.dir?(Path.join(tmp_dir, ".boomlooper/repo"))
      assert File.exists?(Workspace.config_path(tmp_dir))
    end
  end
end
