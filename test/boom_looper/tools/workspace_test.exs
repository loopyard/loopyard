defmodule BoomLooper.Tools.WorkspaceTest do
  use ExUnit.Case
  @moduletag timeout: 15_000

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
      # Only metadata tools remain - infrastructure is written directly via boom-looper-container
      expected = ~w(set_workspace_name set_system_prompt)
      for name <- expected do
        assert name in tool_names, "missing tool: #{name}"
      end
    end
  end

  describe "workspace metadata tools" do
    @describetag :docker
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-ws-tool-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)

      id = "ws-tool-test-#{:rand.uniform(100_000)}"
      workspace_id = BoomLooper.Workspace.workspace_id(tmp_dir)

      # Create workspace config dir so save_to_volume can write
      # (In tests without Docker, volume ops fall back to the virtual dir)
      virtual_dir = Path.join([BoomLooper.Workspace.home_dir(), "workspaces", workspace_id])
      repo_dir = Path.join([virtual_dir, ".boomlooper", "repo"])
      File.mkdir_p!(repo_dir)

      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "Workspace Tool Test",
          working_dir: tmp_dir,
          workspace_id: workspace_id,
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

    test "set_system_prompt updates config", %{agent_id: id, tmp_dir: tmp_dir} do
      WorkspaceTools.do_update_config(id, fn ws -> %{ws | name: "Test"} end, "ok")
      WorkspaceTools.do_update_config(id, fn ws -> %{ws | system_prompt: "Rails project"} end, "ok")

      {:ok, ws} = BoomLooper.Workspace.load(tmp_dir)
      assert ws.name == "Test"
      assert ws.system_prompt == "Rails project"
    end

    test "git fields are preserved through updates", %{agent_id: id, tmp_dir: tmp_dir} do
      WorkspaceTools.do_update_config(id, fn ws ->
        %{ws | name: "Test", git_url: "git@github.com:owner/repo.git", branch: "main"}
      end, "ok")
      WorkspaceTools.do_update_config(id, fn ws -> %{ws | system_prompt: "Updated"} end, "ok")

      {:ok, ws} = BoomLooper.Workspace.load(tmp_dir)
      assert ws.git_url == "git@github.com:owner/repo.git"
      assert ws.branch == "main"
      assert ws.system_prompt == "Updated"
    end
  end

  describe "system messages" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-rebuild-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)

      id = "rebuild-msg-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "System Msg Test",
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

    test "append_message_ets delivers system message to agent state", %{agent_id: id} do
      BoomLooper.ChatAgent.append_message_ets(id, %{
        role: :system,
        content: "Container started.",
        timestamp: DateTime.utc_now()
      })

      Process.sleep(50)
      state = BoomLooper.ChatAgent.get_state(id)
      system_msgs = Enum.filter(state.messages, &(&1[:role] == :system))
      assert length(system_msgs) >= 1
      assert Enum.any?(system_msgs, &(&1.content =~ "Container started"))
    end

    test "append_message_ets broadcasts to PubSub subscribers", %{agent_id: id} do
      BoomLooper.ChatAgent.subscribe(id)

      BoomLooper.ChatAgent.append_message_ets(id, %{
        role: :system,
        content: "Container failed.",
        timestamp: DateTime.utc_now()
      })

      assert_receive {:chat_message, ^id, %{role: :system, content: "Container failed."}}, 1_000
    end

    test "system messages are visible to both agent and subscribers", %{agent_id: id} do
      BoomLooper.ChatAgent.subscribe(id)

      BoomLooper.ChatAgent.append_message_ets(id, %{
        role: :system,
        content: "ARM64 image not available.",
        timestamp: DateTime.utc_now()
      })

      # Subscriber gets it
      assert_receive {:chat_message, ^id, %{role: :system, content: content}}, 1_000
      assert content =~ "ARM64"

      # Agent state has it
      Process.sleep(50)
      state = BoomLooper.ChatAgent.get_state(id)
      system_msgs = Enum.filter(state.messages, &(&1[:role] == :system))
      assert Enum.any?(system_msgs, &(&1.content =~ "ARM64"))
    end
  end

  describe "without bind mount" do
    setup do
      id = "no-bind-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
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

    test "do_update_config returns error without workspace_id", %{agent_id: id} do
      result = WorkspaceTools.do_update_config(id, fn ws -> %{ws | name: "Fallback"} end, "ok")
      assert {:error, msg} = result
      assert msg =~ "has no workspace"
    end
  end
end
