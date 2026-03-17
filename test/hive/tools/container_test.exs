defmodule Hive.Tools.ContainerTest do
  use ExUnit.Case

  alias Hive.Tools.Container

  describe "module structure" do
    test "is a valid MCP server" do
      assert ClaudeCode.MCP.Server.sdk_server?(Container)
    end

    test "has correct server name and 6 tools" do
      info = Container.__tool_server__()
      assert info.name == "hive-container"
      assert length(info.tools) == 6
    end

    test "tool names match expected" do
      tool_names = Container.__tool_server__().tools |> Enum.map(& &1.__tool_name__())
      assert "create" in tool_names
      assert "exec" in tool_names
      assert "copy_in" in tool_names
      assert "copy_out" in tool_names
      assert "stop" in tool_names
      assert "list" in tool_names
    end
  end

  describe "container_name/1" do
    test "generates correct name" do
      assert Container.container_name("abc123") == "hive-dev-abc123"
    end
  end

  # Docker integration tests — run with: mix test --include docker
  describe "container lifecycle" do
    @describetag :docker

    setup do
      agent_id = "test-#{:rand.uniform(100_000)}"

      on_exit(fn ->
        System.cmd("docker", ["rm", "-f", Container.container_name(agent_id)],
          stderr_to_stdout: true
        )
      end)

      %{agent_id: agent_id}
    end

    test "create, exec, and stop", %{agent_id: agent_id} do
      assert {:ok, %{container_name: name}} = Container.do_create(agent_id)
      assert name == Container.container_name(agent_id)

      assert {:ok, output} = Container.do_exec(agent_id, "echo hello")
      assert String.contains?(output, "hello")

      assert {:ok, _} = Container.do_stop(agent_id)
    end

    test "exec fails on non-existent container" do
      assert {:error, _} = Container.do_exec("nonexistent-#{:rand.uniform(100_000)}", "echo hi")
    end

    test "list shows running containers", %{agent_id: agent_id} do
      Container.do_create(agent_id)
      assert {:ok, containers} = Container.do_list()
      assert Enum.any?(containers, &String.contains?(&1.name, agent_id))
    end
  end
end
