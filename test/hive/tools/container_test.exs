defmodule Hive.Tools.ContainerTest do
  use ExUnit.Case

  alias Hive.Tools.Container

  describe "module structure" do
    test "is a valid MCP server" do
      assert ClaudeCode.MCP.Server.sdk_server?(Container)
    end

    test "has correct server name and tools" do
      info = Container.__tool_server__()
      assert info.name == "hive-container"
      assert length(info.tools) == 7
    end

    test "tool names match expected" do
      tool_names = Container.__tool_server__().tools |> Enum.map(& &1.__tool_name__())
      assert "create" in tool_names
      assert "exec" in tool_names
      assert "rebuild" in tool_names
      assert "inspect_env" in tool_names
      assert "stop" in tool_names
      assert "destroy" in tool_names
      assert "list" in tool_names
    end
  end

  # Docker integration tests — run with: mix test --include docker
  describe "container lifecycle" do
    @describetag :docker

    setup do
      agent_id = "test-#{:rand.uniform(100_000)}"

      on_exit(fn ->
        Hive.Docker.destroy(agent_id)
      end)

      %{agent_id: agent_id}
    end

    test "create, exec, and destroy", %{agent_id: agent_id} do
      assert {:ok, %{container: _, port: port, workspace: "/workspace"}} =
               Container.do_create(agent_id)
      assert is_integer(port)

      assert {:ok, output} = Container.do_exec(agent_id, "echo hello")
      assert String.contains?(output, "hello")

      assert {:ok, _} = Container.do_destroy(agent_id)
    end

    test "rebuild preserves workspace files", %{agent_id: agent_id} do
      {:ok, _} = Container.do_create(agent_id)

      # Create a file
      Container.do_exec(agent_id, "echo 'test content' > /workspace/myfile.txt")

      # Rebuild
      assert {:ok, _} = Container.do_rebuild(agent_id)

      # File should survive
      assert {:ok, output} = Container.do_exec(agent_id, "cat /workspace/myfile.txt")
      assert String.contains?(output, "test content")
    end

    test "agent can edit Dockerfile and rebuild", %{agent_id: agent_id} do
      {:ok, _} = Container.do_create(agent_id)

      # Verify python is NOT installed
      assert {:error, _} = Container.do_exec(agent_id, "python3 --version")

      # Edit Dockerfile to add python
      Container.do_exec(agent_id, """
      cat > /workspace/Dockerfile << 'DOCKERFILE'
      FROM ubuntu:22.04
      ENV DEBIAN_FRONTEND=noninteractive
      RUN apt-get update && apt-get install -y curl git build-essential python3 && rm -rf /var/lib/apt/lists/*
      RUN curl -fsSL https://cli.anthropic.com/install.sh | sh
      ENV PATH="/root/.claude/local/bin:${PATH}"
      WORKDIR /workspace
      CMD ["sleep", "infinity"]
      DOCKERFILE
      """)

      # Rebuild
      assert {:ok, _} = Container.do_rebuild(agent_id)

      # Now python should work
      assert {:ok, output} = Container.do_exec(agent_id, "python3 --version")
      assert String.contains?(output, "Python")
    end

    test "exec fails on non-existent container" do
      assert {:error, _} = Container.do_exec("nonexistent-#{:rand.uniform(100_000)}", "echo hi")
    end

    test "list shows running containers", %{agent_id: agent_id} do
      {:ok, _} = Container.do_create(agent_id)
      assert {:ok, containers} = Container.do_list()
      assert Enum.any?(containers, &String.contains?(&1.name, agent_id))
    end
  end
end
