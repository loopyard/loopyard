defmodule Loopyard.WorkspaceTest do
  use ExUnit.Case

  alias Loopyard.Workspace

  @sample_config %{
    "name" => "My Rails App",
    "git_url" => "git@github.com:owner/repo.git",
    "branch" => "main",
    "system_prompt" => "Rails 8 project with PostgreSQL"
  }

  describe "from_map/1" do
    test "parses a full config" do
      ws = Workspace.from_map(@sample_config)

      assert ws.name == "My Rails App"
      assert ws.git_url == "git@github.com:owner/repo.git"
      assert ws.branch == "main"
      assert ws.system_prompt == "Rails 8 project with PostgreSQL"
    end

    test "handles missing optional fields" do
      ws = Workspace.from_map(%{"name" => "Minimal"})

      assert ws.name == "Minimal"
      assert ws.git_url == nil
      assert ws.branch == nil
      assert ws.system_prompt == nil
    end
  end

  describe "to_map/1" do
    test "round-trips through from_map" do
      ws = Workspace.from_map(@sample_config)
      map = Workspace.to_map(ws)

      assert map["name"] == "My Rails App"
      assert map["git_url"] == "git@github.com:owner/repo.git"
      assert map["branch"] == "main"
      assert map["system_prompt"] == "Rails 8 project with PostgreSQL"
    end
  end

  describe "config_path/1" do
    test "returns path to .loopyard/repo/workspace.json" do
      assert Workspace.config_path("/home/user/project") ==
               "/home/user/project/.loopyard/repo/workspace.json"
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
      tmp_dir = Path.join(System.tmp_dir!(), "loopyard-ws-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    test "saves and loads workspace config", %{tmp_dir: tmp_dir} do
      ws = Workspace.from_map(@sample_config)
      assert :ok = Workspace.save(tmp_dir, ws)

      assert {:ok, loaded} = Workspace.load(tmp_dir)
      assert loaded.name == "My Rails App"
      assert loaded.git_url == "git@github.com:owner/repo.git"
      assert loaded.system_prompt == "Rails 8 project with PostgreSQL"
    end

    test "load returns :none when no config exists", %{tmp_dir: tmp_dir} do
      assert :none = Workspace.load(tmp_dir)
    end

    test "creates .loopyard/repo directory if it doesn't exist", %{tmp_dir: tmp_dir} do
      ws = %Workspace{name: "Test"}
      Workspace.save(tmp_dir, ws)

      assert File.dir?(Path.join(tmp_dir, ".loopyard/repo"))
      assert File.exists?(Workspace.config_path(tmp_dir))
    end
  end

  describe "normalize_git_url/1" do
    test "normalizes HTTPS URLs" do
      assert Workspace.normalize_git_url("https://github.com/owner/repo.git") ==
               "github.com/owner/repo"

      assert Workspace.normalize_git_url("https://github.com/owner/repo") ==
               "github.com/owner/repo"
    end

    test "normalizes SSH URLs" do
      assert Workspace.normalize_git_url("git@github.com:owner/repo.git") ==
               "github.com/owner/repo"

      assert Workspace.normalize_git_url("git@github.com:owner/repo") == "github.com/owner/repo"
    end

    test "lowercases URLs" do
      assert Workspace.normalize_git_url("https://GitHub.com/Owner/Repo.git") ==
               "github.com/owner/repo"
    end
  end

  describe "workspace_id_from_git/2" do
    test "returns deterministic ID for same git_url and branch" do
      id1 = Workspace.workspace_id_from_git("git@github.com:owner/repo.git", "main")
      id2 = Workspace.workspace_id_from_git("git@github.com:owner/repo.git", "main")
      assert id1 == id2
      assert is_binary(id1)
      assert String.length(id1) == 4
    end

    test "returns different IDs for different branches" do
      id_main = Workspace.workspace_id_from_git("git@github.com:owner/repo.git", "main")
      id_dev = Workspace.workspace_id_from_git("git@github.com:owner/repo.git", "develop")
      assert id_main != id_dev
    end

    test "returns same ID for equivalent SSH and HTTPS URLs" do
      id_ssh = Workspace.workspace_id_from_git("git@github.com:owner/repo.git", "main")
      id_https = Workspace.workspace_id_from_git("https://github.com/owner/repo.git", "main")
      assert id_ssh == id_https
    end
  end

  describe "project_id_from_git/1" do
    test "returns deterministic ID for same git_url" do
      id1 = Workspace.project_id_from_git("git@github.com:owner/repo.git")
      id2 = Workspace.project_id_from_git("git@github.com:owner/repo.git")
      assert id1 == id2
      assert is_binary(id1)
      assert String.length(id1) == 4
    end

    test "returns same ID for equivalent SSH and HTTPS URLs" do
      id_ssh = Workspace.project_id_from_git("git@github.com:owner/repo.git")
      id_https = Workspace.project_id_from_git("https://github.com/owner/repo.git")
      assert id_ssh == id_https
    end
  end

  describe "load_from_volume/1 and save_to_volume/2" do
    @describetag :docker
    setup do
      volume_name = "loopyard-test-ws-#{:rand.uniform(100_000)}"
      System.cmd("docker", ["volume", "create", volume_name])

      on_exit(fn ->
        System.cmd("docker", ["volume", "rm", "-f", volume_name], stderr_to_stdout: true)
      end)

      %{volume_name: volume_name}
    end

    test "saves and loads workspace config from volume", %{volume_name: volume_name} do
      ws = %Workspace{
        name: "Volume Project",
        git_url: "git@github.com:owner/repo.git",
        branch: "main",
        system_prompt: "Test project"
      }

      assert :ok = Workspace.save_to_volume(volume_name, ws)
      assert {:ok, loaded} = Workspace.load_from_volume(volume_name)

      assert loaded.name == "Volume Project"
      assert loaded.git_url == "git@github.com:owner/repo.git"
      assert loaded.branch == "main"
      assert loaded.system_prompt == "Test project"
    end

    test "load_from_volume returns :none when no config exists", %{volume_name: volume_name} do
      assert :none = Workspace.load_from_volume(volume_name)
    end
  end
end
