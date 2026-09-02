defmodule Loopyard.Tools.WorkspaceTest do
  use Loopyard.AgentCase
  @moduletag timeout: 15_000

  alias Loopyard.Tools.Workspace, as: WorkspaceTools

  describe "module structure" do
    test "is a valid MCP server" do
      assert ClaudeCode.MCP.Server.sdk_server?(WorkspaceTools)
    end

    test "has correct server name" do
      info = WorkspaceTools.__tool_server__()
      assert info.name == "loopyard-workspace"
    end

    test "has all expected tools" do
      tool_names =
        WorkspaceTools.__tool_server__().tools |> Enum.map(& &1.__tool_name__()) |> MapSet.new()

      # Only metadata tools remain - infrastructure is written directly via loopyard-container
      expected = ~w(set_workspace_name set_system_prompt)

      for name <- expected do
        assert name in tool_names, "missing tool: #{name}"
      end
    end
  end

  describe "workspace metadata tools" do
    @describetag :docker
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "loopyard-ws-tool-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)

      id = "ws-tool-test-#{:rand.uniform(100_000)}"
      workspace_id = Loopyard.Workspace.workspace_id(tmp_dir)

      # Create workspace config dir so save_to_volume can write
      # (In tests without Docker, volume ops fall back to the virtual dir)
      virtual_dir = Path.join([Loopyard.Workspace.home_dir(), "workspaces", workspace_id])
      repo_dir = Path.join([virtual_dir, ".loopyard", "repo"])
      File.mkdir_p!(repo_dir)

      {:ok, _pid} =
        Loopyard.TestHelpers.start_agent(
          id: id,
          name: "Workspace Tool Test",
          working_dir: tmp_dir,
          workspace_id: workspace_id,
          started_by: "test"
        )

      on_exit(fn ->
        try do
          Loopyard.ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        Process.sleep(50)
        File.rm_rf!(tmp_dir)
      end)

      %{agent_id: id, tmp_dir: tmp_dir}
    end

    # WorkspaceTools.do_update_config writes to the volume via
    # `Workspace.save_to_volume`, not to the host tmp_dir. The legacy
    # bind-mount fallback that mirrored config back to the host is
    # gone. Read back from the volume to verify.
    defp volume_for(agent_id) do
      ws_id = Loopyard.ChatAgent.get_state(agent_id).workspace_id

      case Loopyard.ProjectRegistry.get_workspace(ws_id) do
        %{volume: vol} when is_binary(vol) -> vol
        _ -> "code-#{ws_id}"
      end
    end

    test "set_workspace_name creates config", %{agent_id: id} do
      assert {:ok, _} =
               WorkspaceTools.do_update_config(id, fn ws -> %{ws | name: "Test"} end, "ok")

      {:ok, ws} = Loopyard.Workspace.load_from_volume(volume_for(id))
      assert ws.name == "Test"
    end

    test "set_system_prompt updates config", %{agent_id: id} do
      WorkspaceTools.do_update_config(id, fn ws -> %{ws | name: "Test"} end, "ok")

      WorkspaceTools.do_update_config(
        id,
        fn ws -> %{ws | system_prompt: "Rails project"} end,
        "ok"
      )

      {:ok, ws} = Loopyard.Workspace.load_from_volume(volume_for(id))
      assert ws.name == "Test"
      assert ws.system_prompt == "Rails project"
    end

    test "git fields are preserved through updates", %{agent_id: id} do
      WorkspaceTools.do_update_config(
        id,
        fn ws ->
          %{ws | name: "Test", git_url: "git@github.com:owner/repo.git", branch: "main"}
        end,
        "ok"
      )

      WorkspaceTools.do_update_config(id, fn ws -> %{ws | system_prompt: "Updated"} end, "ok")

      {:ok, ws} = Loopyard.Workspace.load_from_volume(volume_for(id))
      assert ws.git_url == "git@github.com:owner/repo.git"
      assert ws.branch == "main"
      assert ws.system_prompt == "Updated"
    end
  end

  describe "system messages" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "loopyard-rebuild-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)

      id = "rebuild-msg-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} =
        Loopyard.TestHelpers.start_agent(
          id: id,
          name: "System Msg Test",
          working_dir: tmp_dir,
          bind_mount: tmp_dir,
          started_by: "test"
        )

      on_exit(fn ->
        try do
          Loopyard.ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        Process.sleep(50)
        File.rm_rf!(tmp_dir)
      end)

      %{agent_id: id, tmp_dir: tmp_dir}
    end

    test "append_message_ets delivers system message to agent state", %{agent_id: id} do
      Loopyard.ChatAgent.append_message_ets(id, %{
        role: :system,
        content: "Container started.",
        timestamp: DateTime.utc_now()
      })

      Process.sleep(50)
      state = Loopyard.ChatAgent.get_state(id)
      system_msgs = Enum.filter(state.messages, &(&1[:role] == :system))
      assert length(system_msgs) >= 1
      assert Enum.any?(system_msgs, &(&1.content =~ "Container started"))
    end

    test "append_message_ets broadcasts to PubSub subscribers", %{agent_id: id} do
      Loopyard.ChatAgent.subscribe(id)

      Loopyard.ChatAgent.append_message_ets(id, %{
        role: :system,
        content: "Container failed.",
        timestamp: DateTime.utc_now()
      })

      assert_receive %Loopyard.Events.ChatAgentMessage.Message{
                       agent_id: ^id,
                       msg: %{role: :system, content: "Container failed."}
                     },
                     1_000
    end

    test "system messages are visible to both agent and subscribers", %{agent_id: id} do
      Loopyard.ChatAgent.subscribe(id)

      Loopyard.ChatAgent.append_message_ets(id, %{
        role: :system,
        content: "ARM64 image not available.",
        timestamp: DateTime.utc_now()
      })

      # Subscriber gets it
      assert_receive %Loopyard.Events.ChatAgentMessage.Message{
                       agent_id: ^id,
                       msg: %{role: :system, content: content}
                     },
                     1_000

      assert content =~ "ARM64"

      # Agent state has it
      Process.sleep(50)
      state = Loopyard.ChatAgent.get_state(id)
      system_msgs = Enum.filter(state.messages, &(&1[:role] == :system))
      assert Enum.any?(system_msgs, &(&1.content =~ "ARM64"))
    end
  end

  describe "without bind mount" do
    # The error path under test fires when an agent's workspace_id is
    # nil. Production agents always carry one (RestartController
    # injects it from the WorkspaceGroup), but a malformed ETS row
    # (missing workspace_id) or an agent that hasn't been registered
    # is the realistic case to defend. We poke the summary directly so
    # we don't need to spin up a workspace just to fake the failure.
    setup do
      id = "no-bind-test-#{:rand.uniform(100_000)}"

      :ets.insert(
        :chat_agents,
        {id,
         %{
           id: id,
           name: "No Bind Test",
           workspace_id: nil,
           bind_mount: nil,
           started_at: DateTime.utc_now(),
           last_activity_at: DateTime.utc_now()
         }}
      )

      on_exit(fn -> :ets.delete(:chat_agents, id) end)
      %{agent_id: id}
    end

    test "do_update_config returns error without workspace_id", %{agent_id: id} do
      result = WorkspaceTools.do_update_config(id, fn ws -> %{ws | name: "Fallback"} end, "ok")
      assert {:error, msg} = result
      assert msg =~ "has no workspace"
    end
  end
end
