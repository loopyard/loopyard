defmodule Hive.Tools.ContainerTest do
  use ExUnit.Case

  alias Hive.Tools.Container

  describe "module structure" do
    test "is a valid MCP server" do
      assert ClaudeCode.MCP.Server.sdk_server?(Container)
    end

    test "has correct server name" do
      info = Container.__tool_server__()
      assert info.name == "hive-container"
    end

    test "has all expected tools" do
      tool_names = Container.__tool_server__().tools |> Enum.map(& &1.__tool_name__()) |> MapSet.new()
      expected = ~w(exec logs inspect_env start_service stop_service ports)
      for name <- expected do
        assert name in tool_names, "missing tool: #{name}"
      end
    end
  end

  # Docker integration tests — run with: mix test --include docker
  describe "container operations" do
    @describetag :docker

    setup do
      agent_id = "test-#{:rand.uniform(100_000)}"
      Hive.Docker.create(agent_id, bind_mount: System.tmp_dir!())

      on_exit(fn ->
        Hive.Docker.destroy(agent_id)
      end)

      %{agent_id: agent_id}
    end

    test "exec runs commands", %{agent_id: agent_id} do
      assert {:ok, output} = Container.do_exec(agent_id, "echo hello")
      assert String.contains?(output, "hello")
    end

    test "exec with workdir", %{agent_id: agent_id} do
      Container.do_exec(agent_id, "mkdir -p /workspace/myapp")

      assert {:ok, output} = Container.do_exec(agent_id, "pwd", %{workdir: "/workspace/myapp"})
      assert String.trim(output) == "/workspace/myapp"
    end

    test "exec with timeout option", %{agent_id: agent_id} do
      assert {:ok, _} = Container.do_exec(agent_id, "echo hello", %{timeout: 30_000})
    end

    test "exec fails on non-existent container" do
      assert {:error, _} = Container.do_exec("nonexistent-#{:rand.uniform(100_000)}", "echo hi")
    end
  end
end
