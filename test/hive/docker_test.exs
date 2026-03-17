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

    test "installs claude CLI" do
      assert Docker.base_dockerfile() =~ "cli.anthropic.com"
    end
  end

  describe "cli_wrapper_path" do
    test "creates an executable script" do
      path = Docker.cli_wrapper_path("test-wrapper")
      assert File.exists?(path)
      content = File.read!(path)
      assert content =~ "docker exec -i hive-dev-test-wrapper claude"
      assert content =~ "#!/bin/sh"

      # Clean up
      File.rm(path)
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

      # Rebuild
      assert {:ok, _} = Docker.rebuild(agent_id)
      assert Docker.running?(agent_id)

      # Destroy
      Docker.destroy(agent_id)
      refute Docker.running?(agent_id)
    end
  end
end
