defmodule BoomLooper.Tools.ContainerTest do
  use ExUnit.Case

  alias BoomLooper.Tools.Container

  describe "module structure" do
    test "is a valid MCP server" do
      assert ClaudeCode.MCP.Server.sdk_server?(Container)
    end

    test "has correct server name" do
      info = Container.__tool_server__()
      assert info.name == "boom-looper-container"
    end

    test "has all expected tools" do
      tool_names = Container.__tool_server__().tools |> Enum.map(& &1.__tool_name__()) |> MapSet.new()
      expected = ~w(exec logs inspect_env ports)
      for name <- expected do
        assert name in tool_names, "missing tool: #{name}"
      end
    end

    test "start_service and stop_service tools are removed" do
      tool_names = Container.__tool_server__().tools |> Enum.map(& &1.__tool_name__()) |> MapSet.new()
      refute "start_service" in tool_names
      refute "stop_service" in tool_names
    end
  end

  describe "workspace_id resolution" do
    test "do_exec returns error when agent has no workspace" do
      assert {:error, msg} = Container.do_exec("nonexistent-agent", "echo hi")
      assert msg =~ "no workspace"
    end

    test "do_logs returns error when agent has no workspace" do
      assert {:error, msg} = Container.do_logs("nonexistent-agent")
      assert msg =~ "no workspace"
    end

    test "do_ports returns error when agent has no workspace" do
      assert {:error, msg} = Container.do_ports("nonexistent-agent")
      assert msg =~ "no workspace"
    end

    test "do_inspect returns error when agent has no workspace" do
      assert {:error, msg} = Container.do_inspect("nonexistent-agent")
      assert msg =~ "no workspace"
    end
  end

  # Docker integration tests — run with: mix test --include docker
  describe "container operations via workspace container" do
    @describetag :docker

    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-container-tool-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)
      workspace_id = BoomLooper.Workspace.workspace_id(tmp_dir)

      # Build image and start workspace container
      BoomLooper.Docker.build_workspace_image(workspace_id, BoomLooper.Docker.dockerfile())
      BoomLooper.Docker.start_workspace_container(workspace_id, bind_mount: tmp_dir)

      # Start an agent bound to this workspace
      agent_id = "container-tool-test-#{:rand.uniform(100_000)}"
      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
          id: agent_id,
          name: "Container Tool Test",
          working_dir: tmp_dir,
          bind_mount: tmp_dir,
          started_by: "test"
        )

      on_exit(fn ->
        try do
          BoomLooper.ChatAgent.stop_agent(agent_id)
        catch
          :exit, _ -> :ok
        end
        BoomLooper.Docker.stop_workspace_container(workspace_id)
        File.rm_rf!(tmp_dir)
      end)

      %{agent_id: agent_id, workspace_id: workspace_id, tmp_dir: tmp_dir}
    end

    test "exec runs commands in workspace container", %{agent_id: agent_id} do
      assert {:ok, output} = Container.do_exec(agent_id, "echo hello")
      assert String.contains?(output, "hello")
    end

    test "exec with workdir", %{agent_id: agent_id} do
      Container.do_exec(agent_id, "mkdir -p /workspace/myapp")

      assert {:ok, output} = Container.do_exec(agent_id, "pwd", %{workdir: "/workspace/myapp"})
      assert String.trim(output) == "/workspace/myapp"
    end
  end
end
