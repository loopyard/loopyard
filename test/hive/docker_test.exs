defmodule Hive.DockerTest do
  use ExUnit.Case

  alias Hive.Docker

  describe "naming" do
    test "container_name" do
      assert Docker.container_name("abc") == "hive-dev-abc"
    end

    test "workspace_volume" do
      assert Docker.workspace_volume("abc") == "hive-dev-workspace-abc"
    end

    test "cache_volume" do
      assert Docker.cache_volume("abc") == "hive-dev-cache-abc"
    end

    test "host_port is deterministic" do
      port1 = Docker.host_port("abc")
      port2 = Docker.host_port("abc")
      assert port1 == port2
      assert is_integer(port1)
      assert port1 >= 10_000
    end

    test "host_port differs for different agents" do
      port1 = Docker.host_port("agent-1")
      port2 = Docker.host_port("agent-2")
      assert port1 != port2
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
      assert Docker.network_name() == "hive-net"
    end
  end

  # Full lifecycle tests — run with: mix test --include docker
  describe "full lifecycle" do
    @describetag :docker

    setup do
      agent_id = "docker-test-#{:rand.uniform(100_000)}"
      on_exit(fn -> Docker.destroy(agent_id) end)
      %{agent_id: agent_id}
    end

    test "create, exec, destroy", %{agent_id: agent_id} do
      assert {:ok, _} = Docker.create(agent_id, bind_mount: System.tmp_dir!())
      assert Docker.running?(agent_id)

      # Exec
      assert {:ok, output} = Docker.exec(agent_id, "pwd")
      assert String.contains?(output, "/workspace")

      # git is available
      assert {:ok, git_output} = Docker.exec(agent_id, "which git")
      assert git_output =~ "git"

      # gh CLI is available
      assert {:ok, gh_output} = Docker.exec(agent_id, "which gh")
      assert gh_output =~ "gh"

      # git config is set up
      assert {:ok, git_name} = Docker.exec(agent_id, "git config --global user.name")
      assert git_name != ""

      # Destroy
      Docker.destroy(agent_id)
      refute Docker.running?(agent_id)
    end

    test "exec with workdir option", %{agent_id: agent_id} do
      assert {:ok, _} = Docker.create(agent_id, bind_mount: System.tmp_dir!())

      Docker.exec(agent_id, "mkdir -p /workspace/subdir")

      assert {:ok, output} = Docker.exec(agent_id, "pwd", workdir: "/workspace/subdir")
      assert String.trim(output) == "/workspace/subdir"
    end

    test "container joins hive-net network", %{agent_id: agent_id} do
      assert {:ok, _} = Docker.create(agent_id, bind_mount: System.tmp_dir!())

      name = Docker.container_name(agent_id)
      {output, 0} = System.cmd("docker", ["inspect", "-f", "{{json .NetworkSettings.Networks}}", name], stderr_to_stdout: true)
      assert output =~ "hive-net"
    end
  end

  describe "bind mount" do
    @describetag :docker

    setup do
      agent_id = "bind-test-#{:rand.uniform(100_000)}"
      tmp_dir = Path.join(System.tmp_dir!(), "hive-bind-test-#{agent_id}")
      File.mkdir_p!(tmp_dir)

      on_exit(fn ->
        Docker.destroy(agent_id)
        File.rm_rf!(tmp_dir)
      end)

      %{agent_id: agent_id, tmp_dir: tmp_dir}
    end

    test "bind mount is bidirectional", %{agent_id: agent_id, tmp_dir: tmp_dir} do
      assert {:ok, _} = Docker.create(agent_id, bind_mount: tmp_dir)

      # Write a file on the host, read it from the container
      File.write!(Path.join(tmp_dir, "host-file.txt"), "hello from host")
      assert {:ok, content} = Docker.exec(agent_id, "cat /workspace/host-file.txt")
      assert content =~ "hello from host"

      # Write a file in the container, read it on the host
      Docker.exec(agent_id, "echo 'hello from container' > /workspace/container-file.txt")
      assert File.read!(Path.join(tmp_dir, "container-file.txt")) =~ "hello from container"
    end
  end
end
