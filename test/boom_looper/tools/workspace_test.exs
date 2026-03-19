defmodule BoomLooper.Tools.WorkspaceTest do
  use ExUnit.Case

  alias BoomLooper.Tools.Workspace, as: WorkspaceTools

  describe "module structure" do
    test "is a valid MCP server" do
      assert ClaudeCode.MCP.Server.sdk_server?(WorkspaceTools)
    end

    test "has correct server name" do
      info = WorkspaceTools.__tool_server__()
      assert info.name == "boom-looper-workspace"
    end

    test "has all expected tools" do
      tool_names = WorkspaceTools.__tool_server__().tools |> Enum.map(& &1.__tool_name__()) |> MapSet.new()
      expected = ~w(save_workspace load_workspace start_services stop_services rebuild service_status service_exec)
      for name <- expected do
        assert name in tool_names, "missing tool: #{name}"
      end
    end
  end

  describe "save and load workspace" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-ws-tool-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)

      id = "ws-tool-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} =
        BoomLooper.ChatAgentSupervisor.start_agent(
          id: id,
          name: "Workspace Tool Test",
          working_dir: tmp_dir,
          bind_mount: tmp_dir,
          started_by: "test"
        )

      on_exit(fn ->
        try do
          BoomLooper.ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        Process.sleep(50)
        File.rm_rf!(tmp_dir)
      end)

      %{agent_id: id, tmp_dir: tmp_dir}
    end

    test "save_workspace writes config file", %{agent_id: id, tmp_dir: tmp_dir} do
      config = %{
        "name" => "Test Project",
        "dockerfile" => "FROM ruby:3.4",
        "services" => "[]",
        "processes" => "[]",
        "env_vars" => "{}",
        "system_prompt" => "A test project"
      }

      assert {:ok, _msg} = WorkspaceTools.do_save_workspace(id, config)
      assert File.exists?(BoomLooper.Workspace.config_path(tmp_dir))
    end

    test "load_workspace returns saved config", %{agent_id: id} do
      config = %{
        "name" => "Roundtrip Test",
        "dockerfile" => "FROM node:20",
        "services" => Jason.encode!([
          %{"name" => "redis", "image" => "redis:7", "env" => %{}, "volumes" => [], "ports" => %{}}
        ]),
        "processes" => Jason.encode!([%{"name" => "web", "command" => "npm start"}]),
        "env_vars" => Jason.encode!(%{"NODE_ENV" => "development"}),
        "system_prompt" => "Node project"
      }

      assert {:ok, _} = WorkspaceTools.do_save_workspace(id, config)
      assert {:ok, loaded} = WorkspaceTools.do_load_workspace(id)
      assert loaded["name"] == "Roundtrip Test"
      # Stock services and processes are now separate
      assert length(loaded["services"]) == 1
      redis = hd(loaded["services"])
      assert redis["name"] == "redis"
      assert redis["image"] == "redis:7"
      assert length(loaded["processes"]) == 1
      web = hd(loaded["processes"])
      assert web["name"] == "web"
      assert web["command"] == "npm start"
    end

    test "load_workspace returns nil when no config exists", %{agent_id: id} do
      assert {:ok, nil} = WorkspaceTools.do_load_workspace(id)
    end
  end

  describe "without bind mount" do
    setup do
      id = "no-bind-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} =
        BoomLooper.ChatAgentSupervisor.start_agent(
          id: id,
          name: "No Bind Test",
          working_dir: File.cwd!(),
          started_by: "test"
        )

      on_exit(fn ->
        try do
          BoomLooper.ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        Process.sleep(50)
      end)

      %{agent_id: id}
    end

    test "save_workspace falls back to working_dir", %{agent_id: id} do
      # Without bind_mount, it uses working_dir as fallback
      config = %{"name" => "Fallback Test", "dockerfile" => "FROM ubuntu:24.04"}
      result = WorkspaceTools.do_save_workspace(id, config)
      # Should succeed using working_dir
      assert {:ok, _} = result
    end
  end
end
