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
      expected = ~w(set_dockerfile set_dev_command add_service remove_service set_env_vars set_workspace_name set_system_prompt rebuild start_services stop_services service_status service_exec)
      for name <- expected do
        assert name in tool_names, "missing tool: #{name}"
      end
    end
  end

  describe "granular workspace tools" do
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

    test "set_workspace_name creates config", %{agent_id: id, tmp_dir: tmp_dir} do
      assert {:ok, _} = WorkspaceTools.do_update_config(id, fn ws -> %{ws | name: "Test"} end, "ok")
      assert File.exists?(BoomLooper.Workspace.config_path(tmp_dir))

      {:ok, ws} = BoomLooper.Workspace.load(tmp_dir)
      assert ws.name == "Test"
    end

    test "set_dockerfile updates config", %{agent_id: id, tmp_dir: tmp_dir} do
      WorkspaceTools.do_update_config(id, fn ws -> %{ws | name: "Test"} end, "ok")
      WorkspaceTools.do_update_config(id, fn ws -> %{ws | dockerfile: "FROM ruby:3.4"} end, "ok")

      {:ok, ws} = BoomLooper.Workspace.load(tmp_dir)
      assert ws.name == "Test"
      assert ws.dockerfile == "FROM ruby:3.4"
    end

    test "add_service adds to existing config", %{agent_id: id, tmp_dir: tmp_dir} do
      WorkspaceTools.do_update_config(id, fn ws -> %{ws | name: "Test"} end, "ok")
      WorkspaceTools.do_update_config(id, fn ws ->
        %{ws | services: ws.services ++ [%{name: "redis", image: "redis:7", env: %{}, volumes: [], ports: %{}}]}
      end, "ok")

      {:ok, ws} = BoomLooper.Workspace.load(tmp_dir)
      assert length(ws.services) == 1
      assert hd(ws.services).name == "redis"
    end

    test "remove_service removes from config", %{agent_id: id, tmp_dir: tmp_dir} do
      WorkspaceTools.do_update_config(id, fn ws ->
        %{ws | services: [%{name: "redis", image: "redis:7", env: %{}, volumes: [], ports: %{}}]}
      end, "ok")
      WorkspaceTools.do_update_config(id, fn ws ->
        %{ws | services: Enum.reject(ws.services, &(&1.name == "redis"))}
      end, "ok")

      {:ok, ws} = BoomLooper.Workspace.load(tmp_dir)
      assert ws.services == []
    end

    test "set_dev_command adds process", %{agent_id: id, tmp_dir: tmp_dir} do
      WorkspaceTools.do_update_config(id, fn ws ->
        %{ws | processes: [%{name: "dev", command: "bin/dev", ports: ["3000:3000"]}]}
      end, "ok")

      {:ok, ws} = BoomLooper.Workspace.load(tmp_dir)
      assert length(ws.processes) == 1
      assert hd(ws.processes).name == "dev"
      assert hd(ws.processes).command == "bin/dev"
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

    test "do_update_config falls back to working_dir", %{agent_id: id} do
      result = WorkspaceTools.do_update_config(id, fn ws -> %{ws | name: "Fallback"} end, "ok")
      assert {:ok, _} = result
    end
  end
end
