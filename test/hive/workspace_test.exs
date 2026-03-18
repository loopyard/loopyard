defmodule Hive.WorkspaceTest do
  use ExUnit.Case

  alias Hive.Workspace

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
    test "parses a full config map into a Workspace struct" do
      ws = Workspace.from_map(@sample_config)

      assert ws.name == "My Rails App"
      assert ws.dockerfile == "FROM ruby:3.4\nRUN apt-get update"
      assert length(ws.services) == 1
      assert hd(ws.services).name == "postgres"
      assert hd(ws.services).image == "postgis/postgis:16-3.4"
      assert hd(ws.services).env == %{"POSTGRES_PASSWORD" => "postgres"}
      assert length(ws.processes) == 2
      assert hd(ws.processes).name == "web"
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
  end

  describe "to_map/1" do
    test "round-trips through from_map" do
      ws = Workspace.from_map(@sample_config)
      map = Workspace.to_map(ws)

      assert map["name"] == "My Rails App"
      assert map["dockerfile"] == "FROM ruby:3.4\nRUN apt-get update"
      assert length(map["services"]) == 1
      assert hd(map["services"])["name"] == "postgres"
      assert length(map["processes"]) == 2
      assert map["env_vars"]["DATABASE_URL"] =~ "postgres"
    end
  end

  describe "config_path/1" do
    test "returns path to .hive/workspace.json" do
      assert Workspace.config_path("/home/user/project") == "/home/user/project/.hive/workspace.json"
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
      tmp_dir = Path.join(System.tmp_dir!(), "hive-ws-test-#{:rand.uniform(100_000)}")
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
      assert hd(loaded.services).name == "postgres"
      assert length(loaded.processes) == 2
    end

    test "load returns :none when no config exists", %{tmp_dir: tmp_dir} do
      assert :none = Workspace.load(tmp_dir)
    end

    test "creates .hive directory if it doesn't exist", %{tmp_dir: tmp_dir} do
      ws = %Workspace{name: "Test"}
      Workspace.save(tmp_dir, ws)

      assert File.dir?(Path.join(tmp_dir, ".hive"))
      assert File.exists?(Workspace.config_path(tmp_dir))
    end
  end
end
