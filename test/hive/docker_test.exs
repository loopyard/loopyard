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
      # Not guaranteed but extremely likely for different strings
      port1 = Docker.host_port("agent-1")
      port2 = Docker.host_port("agent-2")
      assert port1 != port2
    end
  end

  describe "base_dockerfile" do
    test "contains ubuntu base" do
      assert Docker.base_dockerfile() =~ "FROM ubuntu"
    end

    test "is a minimal runtime image without claude CLI" do
      refute Docker.base_dockerfile() =~ "claude"
      assert Docker.base_dockerfile() =~ "build-essential"
    end

    test "includes gh CLI installation" do
      assert Docker.base_dockerfile() =~ "gh"
      assert Docker.base_dockerfile() =~ "githubcli-archive-keyring"
    end

    test "includes gnupg for key management" do
      assert Docker.base_dockerfile() =~ "gnupg"
    end
  end

  describe "root_dockerfile" do
    test "uses elixir base image" do
      assert Docker.root_dockerfile() =~ "FROM elixir"
    end

    test "includes build-essential and gh CLI" do
      assert Docker.root_dockerfile() =~ "build-essential"
      assert Docker.root_dockerfile() =~ "gh"
    end

    test "does not include ubuntu base" do
      refute Docker.root_dockerfile() =~ "FROM ubuntu"
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

    test "create, exec, rebuild, destroy", %{agent_id: agent_id} do
      # Create
      assert {:ok, _} = Docker.create(agent_id)
      assert Docker.running?(agent_id)

      # Exec
      assert {:ok, output} = Docker.exec(agent_id, "pwd")
      assert String.contains?(output, "/workspace")

      # Dockerfile exists in workspace
      assert {:ok, df} = Docker.exec(agent_id, "cat /workspace/Dockerfile")
      assert df =~ "FROM ubuntu"

      # gh CLI is available
      assert {:ok, gh_output} = Docker.exec(agent_id, "which gh")
      assert gh_output =~ "gh"

      # git config is set up
      assert {:ok, git_name} = Docker.exec(agent_id, "git config --global user.name")
      assert git_name != ""

      assert {:ok, git_email} = Docker.exec(agent_id, "git config --global user.email")
      assert git_email != ""

      # Rebuild
      assert {:ok, _} = Docker.rebuild(agent_id)
      assert Docker.running?(agent_id)

      # Destroy
      Docker.destroy(agent_id)
      refute Docker.running?(agent_id)
    end

    test "exec with workdir option", %{agent_id: agent_id} do
      assert {:ok, _} = Docker.create(agent_id)

      # Create a subdirectory
      Docker.exec(agent_id, "mkdir -p /workspace/subdir")

      # Run pwd in the subdirectory
      assert {:ok, output} = Docker.exec(agent_id, "pwd", workdir: "/workspace/subdir")
      assert String.trim(output) == "/workspace/subdir"
    end

    test "container joins hive-net network", %{agent_id: agent_id} do
      assert {:ok, _} = Docker.create(agent_id)

      # Inspect the container's network
      name = Docker.container_name(agent_id)
      {output, 0} = System.cmd("docker", ["inspect", "-f", "{{json .NetworkSettings.Networks}}", name], stderr_to_stdout: true)
      assert output =~ "hive-net"
    end
  end

  describe "create with bind_mount" do
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

    test "creates container with bind-mounted workspace", %{agent_id: agent_id, tmp_dir: tmp_dir} do
      assert {:ok, _} = Docker.create(agent_id, bind_mount: tmp_dir, dockerfile: Docker.root_dockerfile())
      assert Docker.running?(agent_id)

      # Verify elixir is available (root dockerfile has it pre-installed)
      assert {:ok, output} = Docker.exec(agent_id, "elixir --version")
      assert output =~ "Elixir"
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

    test "does not seed Dockerfile into workspace", %{agent_id: agent_id, tmp_dir: tmp_dir} do
      assert {:ok, _} = Docker.create(agent_id, bind_mount: tmp_dir)

      # No Dockerfile should be seeded — workspace is the host directory
      refute File.exists?(Path.join(tmp_dir, "Dockerfile"))
    end
  end
end
