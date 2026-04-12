defmodule BoomLooper.EvalRunnerCloneTest do
  @moduledoc """
  Integration test for the eval runner's host-git-clone → Local project
  flow. Tagged :docker because copy_to_volume shells out to Docker.
  """
  use ExUnit.Case

  @moduletag :docker

  alias BoomLooper.ProjectRegistry

  setup do
    BoomLooper.StateKeeper.ensure_tables!()
    :ets.delete_all_objects(:project_registry)
    :ets.delete_all_objects(:workspace_registry)

    # Use a tiny repo that clones fast
    eval_name = "clone-test-#{:rand.uniform(100_000)}"
    project_path = Path.join([File.cwd!(), "evals", eval_name, "project"])

    on_exit(fn ->
      File.rm_rf!(Path.dirname(project_path))
      # Clean up any registered project
      for p <- ProjectRegistry.list_projects(), p.path == project_path do
        ProjectRegistry.remove_project(p.id)
      end
    end)

    %{eval_name: eval_name, project_path: project_path}
  end

  describe "host_git_clone → ProjectRegistry.add flow" do
    test "clones a public repo and registers it as a Local project", %{
      eval_name: _eval_name,
      project_path: project_path
    } do
      git_url = "https://github.com/octocat/Hello-World.git"
      File.mkdir_p!(Path.dirname(project_path))

      # Clone using the host's git binary (same as eval runner does)
      {output, exit_code} =
        System.cmd("git", ["clone", "--branch", "master", "--depth", "1", git_url, project_path],
          stderr_to_stdout: true
        )

      assert exit_code == 0, "git clone failed: #{output}"
      assert File.dir?(project_path)
      assert File.exists?(Path.join(project_path, "README"))

      # Register as a Local project — this is what the eval runner does
      assert {:ok, project, workspace} = ProjectRegistry.add(project_path)
      assert project.source_type == :local
      assert project.path == project_path
      assert workspace.is_main == true
      assert workspace.worktree_path == project_path

      # Volume should be created (even if empty at this point — ServiceManager
      # seeds it on start)
      volume_name = BoomLooper.Workspace.volume_name_for(workspace.id)
      assert volume_name =~ "bl-"
    end

    test "copy_to_volume puts files into a Docker volume", %{project_path: project_path} do
      # Create a fake project dir with a file
      File.mkdir_p!(project_path)
      File.write!(Path.join(project_path, "hello.txt"), "world")

      volume_name = "bl-clone-test-#{:rand.uniform(100_000)}-code"

      try do
        :ok = BoomLooper.VolumeManager.create_volume(volume_name)

        case BoomLooper.VolumeManager.copy_to_volume(volume_name, project_path) do
          {:ok, _} ->
            # Verify the file is in the volume
            case BoomLooper.VolumeManager.read_file(volume_name, "hello.txt") do
              {:ok, content} -> assert content == "world"
              {:error, reason} -> flunk("read_file failed: #{inspect(reason)}")
            end

          {:error, reason} ->
            flunk("copy_to_volume failed: #{inspect(reason)}")
        end
      after
        BoomLooper.VolumeManager.delete_volume(volume_name)
      end
    end
  end
end
