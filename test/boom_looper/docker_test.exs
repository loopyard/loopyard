defmodule BoomLooper.DockerTest do
  use ExUnit.Case

  alias BoomLooper.Docker

  describe "naming" do
    test "workspace_container_name" do
      assert Docker.workspace_container_name("abcd") == "boom-looper-ws-abcd"
    end

    test "workspace_image_name" do
      assert Docker.workspace_image_name("abcd") == "boom-looper-ws-abcd"
    end

    test "cache_volume_for_workspace" do
      assert Docker.cache_volume_for_workspace("abcd") == "boom-looper-ws-cache-abcd"
    end
  end

  describe "dockerfile" do
    test "uses generic ubuntu base image" do
      assert Docker.dockerfile() =~ "FROM ubuntu:24.04"
    end

    test "includes build-essential and gh CLI" do
      assert Docker.dockerfile() =~ "build-essential"
      assert Docker.dockerfile() =~ "gh"
      assert Docker.dockerfile() =~ "githubcli-archive-keyring"
    end

    test "includes gnupg for key management" do
      assert Docker.dockerfile() =~ "gnupg"
    end
  end

  describe "network_name" do
    test "returns the shared network name" do
      assert Docker.network_name() == "boom-looper-net"
    end
  end

  describe "list_containers/1" do
    @describetag :docker

    test "returns a list" do
      result = Docker.list_containers()
      assert is_list(result)
    end

    test "classifies workspace containers correctly" do
      assert is_list(Docker.list_containers(prefix: "boom-looper-ws-"))
      assert is_list(Docker.list_containers(prefix: "boom-looper-svc-"))
    end
  end

  describe "build_process_entrypoint/1" do
    test "generates bash script with trap and wait" do
      processes = [
        %{name: "web", command: "bin/rails server -p 3000"},
        %{name: "css", command: "bin/rails tailwindcss:watch"}
      ]

      script = Docker.build_process_entrypoint(processes)
      assert script =~ "#!/bin/bash"
      assert script =~ "trap"
      assert script =~ "SIGTERM"
      assert script =~ "wait"
      assert script =~ "bin/rails server -p 3000"
      assert script =~ "bin/rails tailwindcss:watch"
      assert script =~ "web"
      assert script =~ "css"
      assert script =~ "sed"
    end

    test "empty processes list generates valid script" do
      script = Docker.build_process_entrypoint([])
      assert script =~ "#!/bin/bash"
      assert script =~ "wait"
    end
  end

  # Workspace container lifecycle tests — run with: mix test --include docker
  describe "workspace container lifecycle" do
    @describetag :docker

    setup do
      workspace_id = "ws-test-#{:rand.uniform(100_000)}"
      on_exit(fn -> Docker.stop_workspace_container(workspace_id) end)
      %{workspace_id: workspace_id}
    end

    test "start, exec, stop workspace container", %{workspace_id: workspace_id} do
      assert {:ok, _} = Docker.build_workspace_image(workspace_id, Docker.dockerfile())

      assert {:ok, _} = Docker.start_workspace_container(workspace_id, bind_mount: System.tmp_dir!())
      assert Docker.workspace_container_running?(workspace_id)

      assert {:ok, output} = Docker.exec_workspace(workspace_id, "pwd")
      assert output =~ "/workspace"

      # git is available
      assert {:ok, git_output} = Docker.exec_workspace(workspace_id, "which git")
      assert git_output =~ "git"

      # gh CLI is available
      assert {:ok, gh_output} = Docker.exec_workspace(workspace_id, "which gh")
      assert gh_output =~ "gh"

      # git config is set up
      assert {:ok, git_name} = Docker.exec_workspace(workspace_id, "git config --global user.name")
      assert git_name != ""

      Docker.stop_workspace_container(workspace_id)
      refute Docker.workspace_container_running?(workspace_id)
    end

    test "exec with workdir option", %{workspace_id: workspace_id} do
      assert {:ok, _} = Docker.build_workspace_image(workspace_id, Docker.dockerfile())
      assert {:ok, _} = Docker.start_workspace_container(workspace_id, bind_mount: System.tmp_dir!())

      Docker.exec_workspace(workspace_id, "mkdir -p /workspace/subdir")

      assert {:ok, output} = Docker.exec_workspace(workspace_id, "pwd", workdir: "/workspace/subdir")
      assert String.trim(output) == "/workspace/subdir"
    end

    test "workspace container joins hive-net network", %{workspace_id: workspace_id} do
      assert {:ok, _} = Docker.build_workspace_image(workspace_id, Docker.dockerfile())
      assert {:ok, _} = Docker.start_workspace_container(workspace_id, bind_mount: System.tmp_dir!())

      name = Docker.workspace_container_name(workspace_id)
      {output, 0} = System.cmd("docker", ["inspect", "-f", "{{json .NetworkSettings.Networks}}", name], stderr_to_stdout: true)
      assert output =~ "boom-looper-net"
    end
  end

  describe "bind mount" do
    @describetag :docker

    setup do
      workspace_id = "bind-test-#{:rand.uniform(100_000)}"
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-bind-test-#{workspace_id}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn ->
        Docker.stop_workspace_container(workspace_id)
        File.rm_rf!(tmp_dir)
      end)

      %{workspace_id: workspace_id, tmp_dir: tmp_dir}
    end

    test "bind mount is bidirectional", %{workspace_id: workspace_id, tmp_dir: tmp_dir} do
      assert {:ok, _} = Docker.build_workspace_image(workspace_id, Docker.dockerfile())
      assert {:ok, _} = Docker.start_workspace_container(workspace_id, bind_mount: tmp_dir)

      # Write a file on the host, read it from the container
      File.write!(Path.join(tmp_dir, "host-file.txt"), "hello from host")
      assert {:ok, content} = Docker.exec_workspace(workspace_id, "cat /workspace/host-file.txt")
      assert content =~ "hello from host"

      # Write a file in the container, read it on the host
      Docker.exec_workspace(workspace_id, "echo 'hello from container' > /workspace/container-file.txt")
      assert File.read!(Path.join(tmp_dir, "container-file.txt")) =~ "hello from container"
    end
  end
end
