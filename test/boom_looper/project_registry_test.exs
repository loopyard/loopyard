defmodule BoomLooper.ProjectRegistryTest do
  use ExUnit.Case

  alias BoomLooper.ProjectRegistry

  setup do
    ProjectRegistry.ensure_ets_tables()
    # Clean up any existing state
    ProjectRegistry.list_projects() |> Enum.each(&ProjectRegistry.remove_project(&1.id))
    :ok
  end

  describe "add/1" do
    test "registers a git repo as a project with main workspace" do
      path = File.cwd!()
      assert {:ok, project, workspace} = ProjectRegistry.add(path)
      assert project.is_git == true
      assert workspace.is_main == true
      assert workspace.project_id == project.id
    end

    test "returns error for non-existent path" do
      assert {:error, _} = ProjectRegistry.add("/nonexistent/path/#{:rand.uniform(100_000)}")
    end

    test "is idempotent — adding same path twice returns same project" do
      path = File.cwd!()
      {:ok, project1, _} = ProjectRegistry.add(path)
      {:ok, project2, _} = ProjectRegistry.add(path)
      assert project1.id == project2.id
    end

    test "discovers existing worktrees" do
      path = File.cwd!()
      {:ok, project, _} = ProjectRegistry.add(path)
      workspaces = ProjectRegistry.list_workspaces(project.id)
      # Should have at least the main workspace
      assert length(workspaces) >= 1
    end
  end

  describe "list_projects/0" do
    test "lists all registered projects" do
      path = File.cwd!()
      ProjectRegistry.add(path)
      projects = ProjectRegistry.list_projects()
      assert length(projects) >= 1
    end
  end

  describe "get_project/1" do
    test "returns project by ID" do
      path = File.cwd!()
      {:ok, project, _} = ProjectRegistry.add(path)
      assert ProjectRegistry.get_project(project.id) == project
    end

    test "returns nil for unknown ID" do
      assert ProjectRegistry.get_project("nonexistent") == nil
    end
  end

  describe "list_workspaces/1" do
    test "returns workspaces for a project" do
      path = File.cwd!()
      {:ok, project, _} = ProjectRegistry.add(path)
      workspaces = ProjectRegistry.list_workspaces(project.id)
      assert length(workspaces) >= 1
      assert hd(workspaces).project_id == project.id
    end

    test "main workspace sorts first" do
      path = File.cwd!()
      {:ok, project, _} = ProjectRegistry.add(path)
      workspaces = ProjectRegistry.list_workspaces(project.id)
      first = hd(workspaces)
      assert first.is_main == true
    end
  end

  describe "remove_project/1" do
    test "removes project and all workspaces" do
      path = File.cwd!()
      {:ok, project, _} = ProjectRegistry.add(path)
      assert :ok = ProjectRegistry.remove_project(project.id)
      assert ProjectRegistry.get_project(project.id) == nil
      assert ProjectRegistry.list_workspaces(project.id) == []
    end
  end
end
