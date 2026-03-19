defmodule BoomLooper.WorkspaceRegistryTest do
  use ExUnit.Case, async: true

  alias BoomLooper.WorkspaceRegistry

  setup do
    # Use a unique temp dir for each test to avoid conflicts
    tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-ws-reg-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "add/1" do
    test "adds a workspace and returns {:ok, workspace}", %{tmp_dir: tmp_dir} do
      assert {:ok, ws} = WorkspaceRegistry.add(tmp_dir)
      assert ws.path == tmp_dir
      assert ws.name == Path.basename(tmp_dir)
      assert ws.id
      assert ws.added_at
    end

    test "returns error for nonexistent directory" do
      assert {:error, msg} = WorkspaceRegistry.add("/no/such/path/xyz")
      assert msg =~ "does not exist"
    end

    test "expands paths", %{tmp_dir: tmp_dir} do
      # Add with unexpanded path
      {:ok, ws} = WorkspaceRegistry.add(tmp_dir)
      assert ws.path == Path.expand(tmp_dir)
    end

    test "uses workspace.json name when available", %{tmp_dir: tmp_dir} do
      ws_config = %BoomLooper.Workspace{
        name: "My Cool Project",
        dockerfile: "FROM ubuntu:22.04",
        services: [],
        processes: [],
        env_vars: %{},
        system_prompt: nil
      }

      BoomLooper.Workspace.save(tmp_dir, ws_config)

      {:ok, ws} = WorkspaceRegistry.add(tmp_dir)
      assert ws.name == "My Cool Project"
    end
  end

  describe "get/1" do
    test "returns workspace by id", %{tmp_dir: tmp_dir} do
      {:ok, ws} = WorkspaceRegistry.add(tmp_dir)
      assert WorkspaceRegistry.get(ws.id) == ws
    end

    test "returns nil for unknown id" do
      assert WorkspaceRegistry.get("nonexistent") == nil
    end
  end

  describe "list/0" do
    test "returns all workspaces sorted by name", %{tmp_dir: tmp_dir} do
      dir_b = Path.join(tmp_dir, "beta")
      dir_a = Path.join(tmp_dir, "alpha")
      File.mkdir_p!(dir_b)
      File.mkdir_p!(dir_a)

      {:ok, _} = WorkspaceRegistry.add(dir_b)
      {:ok, _} = WorkspaceRegistry.add(dir_a)

      names = WorkspaceRegistry.list() |> Enum.map(& &1.name)
      alpha_idx = Enum.find_index(names, &(&1 == "alpha"))
      beta_idx = Enum.find_index(names, &(&1 == "beta"))
      assert alpha_idx < beta_idx
    end
  end

  describe "remove/1" do
    test "removes a workspace", %{tmp_dir: tmp_dir} do
      {:ok, ws} = WorkspaceRegistry.add(tmp_dir)
      assert WorkspaceRegistry.get(ws.id) != nil

      WorkspaceRegistry.remove(ws.id)
      assert WorkspaceRegistry.get(ws.id) == nil
    end
  end
end
