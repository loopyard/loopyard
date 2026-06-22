defmodule Loopyard.Tools.ContainerTest do
  use ExUnit.Case

  alias Loopyard.Tools.Container

  alias Loopyard.Tools.Container.{
    Exec,
    WriteFile,
    ReadFile,
    Logs,
    InspectEnv,
    Ports,
    ServiceContainers,
    WorkspaceInfo,
    Volumes,
    Helpers
  }

  describe "toolkit" do
    test "has correct server name" do
      info = Container.__tool_server__()
      assert info.name == "loopyard-container"
    end

    test "has all expected tools" do
      tool_names =
        Container.__tool_server__().tools |> Enum.map(& &1.__tool_name__()) |> MapSet.new()

      # `docker` (raw CLI) is intentionally excluded — it was a workspace
      # escape hatch. See Loopyard.Tools.Container for the rationale.
      expected =
        ~w(exec logs inspect_env ports service_containers write_file read_file
           edit multi_edit grep glob probe_http tree inspect_service read_files
           docker_compose workspace_info volumes file_url app_url git file_info
           ask_user propose_fork propose_integrate propose_delete_workspace)

      assert MapSet.size(tool_names) == length(expected)

      for name <- expected do
        assert name in tool_names, "missing tool: #{name}"
      end
    end

    test "each tool module exports the required interface" do
      for tool_mod <- Container.__tool_server__().tools do
        assert function_exported?(tool_mod, :__tool_name__, 0),
               "#{tool_mod} missing __tool_name__/0"

        assert function_exported?(tool_mod, :__description__, 0),
               "#{tool_mod} missing __description__/0"

        assert function_exported?(tool_mod, :input_schema, 0),
               "#{tool_mod} missing input_schema/0"

        assert function_exported?(tool_mod, :execute, 2), "#{tool_mod} missing execute/2"

        schema = tool_mod.input_schema()
        assert is_map(schema), "#{tool_mod}.input_schema/0 must return a map"
        assert schema["type"] == "object", "#{tool_mod} schema must have type object"
      end
    end

    test "every tool schema is JSON-serializable (catches sigil/AST leaks)" do
      # This test would have caught the ~s|...| sigil bug that crashed
      # tools/list and created a hot restart loop hammering the API.
      for tool_mod <- Container.__tool_server__().tools do
        schema = tool_mod.input_schema()
        description = tool_mod.__description__()
        name = tool_mod.__tool_name__()

        # Build the full MCP tool definition — exactly what tools/list returns
        tool_def = %{
          "name" => name,
          "description" => description,
          "inputSchema" => schema
        }

        assert {:ok, _json} = Jason.encode(tool_def),
               "#{tool_mod} tool definition is not JSON-serializable — " <>
                 "check for unevaluated sigils or AST nodes in params"
      end
    end
  end

  describe "Exec validation" do
    test "rejects oversized commands" do
      big_cmd = String.duplicate("x", 10_001)
      assert {:error, msg} = Exec.execute(%{agent_id: "any", command: big_cmd}, %{})
      assert msg =~ "10000 byte limit"
    end

    test "rejects commands with null bytes" do
      assert {:error, msg} = Exec.execute(%{agent_id: "any", command: "echo \0 hello"}, %{})
      assert msg =~ "null bytes"
    end

    test "rejects invalid timeout" do
      assert {:error, msg} =
               Exec.execute(%{agent_id: "any", command: "echo hi", timeout: 9999}, %{})

      assert msg =~ "between 1 and 3600"
    end

    test "returns error when agent has no workspace" do
      assert {:error, msg} = Exec.execute(%{agent_id: "nonexistent", command: "echo hi"}, %{})
      assert msg =~ "no workspace"
    end
  end

  describe "WriteFile validation" do
    test "rejects paths escaping workspace" do
      assert {:error, msg} =
               WriteFile.execute(%{agent_id: "any", path: "../etc/passwd", content: "x"}, %{})

      assert msg =~ "must be within /workspace"
    end

    test "rejects absolute paths outside workspace" do
      assert {:error, msg} =
               WriteFile.execute(%{agent_id: "any", path: "/etc/passwd", content: "x"}, %{})

      assert msg =~ "must be within /workspace"
    end

    test "rejects oversized content" do
      big = String.duplicate("x", 1_000_001)

      assert {:error, msg} =
               WriteFile.execute(%{agent_id: "any", path: "test.txt", content: big}, %{})

      assert msg =~ "1000000 byte limit"
    end

    test "rejects oversized paths" do
      long_path = String.duplicate("a/", 251)

      assert {:error, msg} =
               WriteFile.execute(%{agent_id: "any", path: long_path, content: "x"}, %{})

      assert msg =~ "500 byte limit"
    end

    test "returns error when agent has no workspace" do
      assert {:error, msg} =
               WriteFile.execute(%{agent_id: "nonexistent", path: "test.txt", content: "x"}, %{})

      assert msg =~ "no workspace"
    end
  end

  describe "ReadFile validation" do
    test "rejects paths escaping workspace" do
      assert {:error, msg} = ReadFile.execute(%{agent_id: "any", path: "../etc/passwd"}, %{})
      assert msg =~ "must be within /workspace"
    end

    test "rejects absolute paths outside workspace" do
      assert {:error, msg} = ReadFile.execute(%{agent_id: "any", path: "/etc/passwd"}, %{})
      assert msg =~ "must be within /workspace"
    end

    test "returns error when agent has no workspace" do
      assert {:error, msg} = ReadFile.execute(%{agent_id: "nonexistent", path: "test.txt"}, %{})
      assert msg =~ "no workspace"
    end
  end

  describe "Helpers.validate_workspace_path/1" do
    test "accepts relative paths" do
      assert {:ok, "/workspace/src/main.rs"} = Helpers.validate_workspace_path("src/main.rs")
    end

    test "accepts absolute paths within /workspace" do
      assert {:ok, "/workspace/src/main.rs"} =
               Helpers.validate_workspace_path("/workspace/src/main.rs")
    end

    test "accepts /workspace itself" do
      assert {:ok, "/workspace"} = Helpers.validate_workspace_path("/workspace")
    end

    test "rejects path traversal with .." do
      assert {:error, msg} = Helpers.validate_workspace_path("../../../etc/passwd")
      assert msg =~ "must be within /workspace"
    end

    test "rejects absolute paths outside /workspace" do
      assert {:error, msg} = Helpers.validate_workspace_path("/etc/passwd")
      assert msg =~ "must be within /workspace"
    end

    test "rejects paths with null bytes" do
      assert {:error, msg} = Helpers.validate_workspace_path("src/main\0.rs")
      assert msg =~ "null bytes"
    end

    test "rejects non-string input" do
      assert {:error, _} = Helpers.validate_workspace_path(123)
    end

    test "normalizes paths with embedded .." do
      assert {:error, _} = Helpers.validate_workspace_path("/workspace/foo/../../etc")
    end

    test "allows paths with .. that stay inside workspace" do
      assert {:ok, "/workspace/bar"} = Helpers.validate_workspace_path("/workspace/foo/../bar")
    end
  end

  describe "workspace_id resolution" do
    test "Logs returns error when agent has no workspace" do
      assert {:error, msg} = Logs.execute(%{agent_id: "nonexistent"}, %{})
      assert msg =~ "no workspace"
    end

    test "Ports returns error when agent has no workspace" do
      assert {:error, msg} = Ports.execute(%{agent_id: "nonexistent"}, %{})
      assert msg =~ "no workspace"
    end

    test "InspectEnv returns error when agent has no workspace" do
      assert {:error, msg} = InspectEnv.execute(%{agent_id: "nonexistent"}, %{})
      assert msg =~ "no workspace"
    end

    test "ServiceContainers returns error when agent has no workspace" do
      assert {:error, msg} = ServiceContainers.execute(%{agent_id: "nonexistent"}, %{})
      assert msg =~ "no workspace"
    end

    test "WorkspaceInfo returns error when agent has no workspace" do
      assert {:error, msg} = WorkspaceInfo.execute(%{agent_id: "nonexistent"}, %{})
      assert msg =~ "no workspace"
    end

    test "Volumes returns error when agent has no workspace" do
      assert {:error, msg} = Volumes.execute(%{agent_id: "nonexistent"}, %{})
      assert msg =~ "no workspace"
    end
  end

  # Docker integration tests — run with: mix test --include docker
  describe "container operations" do
    @describetag :docker

    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "loopyard-container-tool-test-#{:rand.uniform(100_000)}")

      File.mkdir_p!(tmp_dir)
      workspace_id = Loopyard.Workspace.workspace_id(tmp_dir)

      repo_dir = Path.join(tmp_dir, ".loopyard/repo")
      File.mkdir_p!(repo_dir)
      File.write!(Path.join(repo_dir, "workspace.json"), Jason.encode!(%{"name" => "test"}))

      workspace_dir = Path.join(tmp_dir, ".loopyard/workspace")
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
      Loopyard.Compose.up(tmp_dir, workspace_id)

      agent_id = "container-tool-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} =
        Loopyard.TestHelpers.start_agent(
          id: agent_id,
          name: "Container Tool Test",
          working_dir: tmp_dir,
          bind_mount: tmp_dir,
          started_by: "test"
        )

      on_exit(fn ->
        try do
          Loopyard.ChatAgent.stop_agent(agent_id)
        catch
          :exit, _ -> :ok
        end

        Loopyard.Compose.down(tmp_dir, workspace_id)
        File.rm_rf!(tmp_dir)
      end)

      %{agent_id: agent_id, workspace_id: workspace_id, tmp_dir: tmp_dir}
    end

    test "exec runs commands in workspace container", %{agent_id: agent_id} do
      assert {:ok, output} = Exec.execute(%{agent_id: agent_id, command: "echo hello"}, %{})
      assert String.contains?(output, "hello")
    end

    test "exec with workdir", %{agent_id: agent_id} do
      Exec.execute(%{agent_id: agent_id, command: "mkdir -p /workspace/myapp"}, %{})

      assert {:ok, output} =
               Exec.execute(
                 %{agent_id: agent_id, command: "pwd", workdir: "/workspace/myapp"},
                 %{}
               )

      assert String.trim(output) == "/workspace/myapp"
    end
  end
end
