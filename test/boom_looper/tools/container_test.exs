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

    test "has all 20 expected tools" do
      tool_names = Container.__tool_server__().tools |> Enum.map(& &1.__tool_name__()) |> MapSet.new()

      expected =
        ~w(exec exec_stream logs inspect_env ports service_containers write_file read_file
           edit multi_edit grep glob probe_http tree inspect_service read_files
           docker docker_compose workspace_info volumes)

      assert MapSet.size(tool_names) == 20

      for name <- expected do
        assert name in tool_names, "missing tool: #{name}"
      end
    end

    test "each tool module exports the required interface" do
      for tool_mod <- Container.__tool_server__().tools do
        assert function_exported?(tool_mod, :__tool_name__, 0), "#{tool_mod} missing __tool_name__/0"
        assert function_exported?(tool_mod, :__description__, 0), "#{tool_mod} missing __description__/0"
        assert function_exported?(tool_mod, :input_schema, 0), "#{tool_mod} missing input_schema/0"
        assert function_exported?(tool_mod, :execute, 2), "#{tool_mod} missing execute/2"

        schema = tool_mod.input_schema()
        assert is_map(schema), "#{tool_mod}.input_schema/0 must return a map"
        assert schema["type"] == "object", "#{tool_mod} schema must have type object"
      end
    end
  end

  describe "input validation" do
    test "do_exec rejects oversized commands" do
      big_cmd = String.duplicate("x", 10_001)
      assert {:error, msg} = Container.do_exec("any-agent", big_cmd)
      assert msg =~ "10000 byte limit"
    end

    test "do_exec rejects commands with null bytes" do
      assert {:error, msg} = Container.do_exec("any-agent", "echo \0 hello")
      assert msg =~ "null bytes"
    end

    test "do_exec rejects invalid timeout" do
      assert {:error, msg} = Container.do_exec("any-agent", "echo hi", %{timeout: 9999})
      assert msg =~ "between 1 and 3600"
    end

    test "do_write_file rejects oversized content" do
      big = String.duplicate("x", 1_000_001)
      assert {:error, msg} = Container.do_write_file("any-agent", "test.txt", big)
      assert msg =~ "1000000 byte limit"
    end

    test "do_write_file rejects oversized paths" do
      long_path = String.duplicate("a/", 251)
      assert {:error, msg} = Container.do_write_file("any-agent", long_path, "content")
      assert msg =~ "500 byte limit"
    end
  end

  describe "validate_workspace_path/1" do
    test "accepts relative paths" do
      assert {:ok, "/workspace/src/main.rs"} = Container.validate_workspace_path("src/main.rs")
    end

    test "accepts absolute paths within /workspace" do
      assert {:ok, "/workspace/src/main.rs"} = Container.validate_workspace_path("/workspace/src/main.rs")
    end

    test "accepts /workspace itself" do
      assert {:ok, "/workspace"} = Container.validate_workspace_path("/workspace")
    end

    test "rejects path traversal with .." do
      assert {:error, msg} = Container.validate_workspace_path("../../../etc/passwd")
      assert msg =~ "must be within /workspace"
    end

    test "rejects absolute paths outside /workspace" do
      assert {:error, msg} = Container.validate_workspace_path("/etc/passwd")
      assert msg =~ "must be within /workspace"
    end

    test "rejects paths with null bytes" do
      assert {:error, msg} = Container.validate_workspace_path("src/main\0.rs")
      assert msg =~ "null bytes"
    end

    test "rejects non-string input" do
      assert {:error, _} = Container.validate_workspace_path(123)
    end

    test "normalizes paths with embedded .." do
      # /workspace/foo/../../etc → /etc (outside workspace)
      assert {:error, _} = Container.validate_workspace_path("/workspace/foo/../../etc")
    end

    test "allows paths with .. that stay inside workspace" do
      assert {:ok, "/workspace/bar"} = Container.validate_workspace_path("/workspace/foo/../bar")
    end
  end

  describe "do_write_file/3" do
    test "rejects paths escaping workspace" do
      assert {:error, msg} = Container.do_write_file("any-agent", "../etc/passwd", "content")
      assert msg =~ "must be within /workspace"
    end

    test "rejects absolute paths outside workspace" do
      assert {:error, msg} = Container.do_write_file("any-agent", "/etc/passwd", "content")
      assert msg =~ "must be within /workspace"
    end

    test "returns error when agent has no workspace" do
      assert {:error, msg} = Container.do_write_file("nonexistent-agent", "test.txt", "content")
      assert msg =~ "no workspace"
    end
  end

  describe "do_read_file/2" do
    test "rejects paths escaping workspace" do
      assert {:error, msg} = Container.do_read_file("any-agent", "../etc/passwd")
      assert msg =~ "must be within /workspace"
    end

    test "rejects absolute paths outside workspace" do
      assert {:error, msg} = Container.do_read_file("any-agent", "/etc/passwd")
      assert msg =~ "must be within /workspace"
    end

    test "returns error when agent has no workspace" do
      assert {:error, msg} = Container.do_read_file("nonexistent-agent", "test.txt")
      assert msg =~ "no workspace"
    end
  end

  describe "do_docker/2" do
    @describetag :docker

    test "runs docker commands" do
      assert {:ok, output} = Container.do_docker("ps --format '{{.Names}}'", 30)
      # Should return something (even if empty)
      assert is_binary(output)
    end

    test "returns error for invalid commands" do
      assert {:error, _} = Container.do_docker("invalid-subcommand-xyz", 5)
    end
  end

  describe "do_workspace_info/1" do
    test "returns error when agent has no workspace" do
      assert {:error, msg} = Container.do_workspace_info("nonexistent-agent")
      assert msg =~ "no workspace"
    end
  end

  describe "do_volumes/2" do
    test "returns error when agent has no workspace" do
      assert {:error, msg} = Container.do_volumes("nonexistent-agent", "list")
      assert msg =~ "no workspace"
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

    test "do_service_containers returns error when agent has no workspace" do
      assert {:error, msg} = Container.do_service_containers("nonexistent-agent")
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

      # Write workspace config
      repo_dir = Path.join(tmp_dir, ".boomlooper/repo")
      File.mkdir_p!(repo_dir)
      File.write!(Path.join(repo_dir, "workspace.json"), Jason.encode!(%{"name" => "test"}))

      # Write docker-compose.yml directly (new architecture)
      workspace_dir = Path.join(tmp_dir, ".boomlooper/workspace")
      File.mkdir_p!(workspace_dir)
      compose_content = """
      {
        "services": {
          "workspace": {
            "image": "ubuntu:24.04",
            "command": ["sleep", "infinity"],
            "working_dir": "/workspace"
          }
        }
      }
      """
      File.write!(Path.join(workspace_dir, "docker-compose.yml"), compose_content)
      BoomLooper.Compose.up(tmp_dir, workspace_id)

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
        BoomLooper.Compose.down(tmp_dir, workspace_id)
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
