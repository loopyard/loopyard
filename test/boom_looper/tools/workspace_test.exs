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
      expected = ~w(set_dockerfile set_dev_command add_service remove_service set_env_vars set_workspace_name set_system_prompt rebuild service_status)
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
        BoomLooper.TestHelpers.start_agent(
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

  describe "rebuild system messages" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "boom-looper-rebuild-test-#{:rand.uniform(100_000)}")
      File.mkdir_p!(tmp_dir)

      id = "rebuild-msg-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "Rebuild Msg Test",
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
        content: "Rebuild complete.",
        timestamp: DateTime.utc_now()
      })

      Process.sleep(50)
      state = BoomLooper.ChatAgent.get_state(id)
      system_msgs = Enum.filter(state.messages, &(&1[:role] == :system))
      assert length(system_msgs) >= 1
      assert Enum.any?(system_msgs, &(&1.content =~ "Rebuild complete"))
    end

    test "append_message_ets broadcasts to PubSub subscribers", %{agent_id: id} do
      BoomLooper.ChatAgent.subscribe(id)

      BoomLooper.ChatAgent.append_message_ets(id, %{
        role: :system,
        content: "Rebuild failed.",
        timestamp: DateTime.utc_now()
      })

      assert_receive {:chat_message, ^id, %{role: :system, content: "Rebuild failed."}}, 1_000
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

  describe "parse_env/1" do
    test "nil returns empty map" do
      assert WorkspaceTools.parse_env(nil) == %{}
    end

    test "passes through map" do
      assert WorkspaceTools.parse_env(%{"KEY" => "val"}) == %{"KEY" => "val"}
    end

    test "parses JSON object" do
      assert WorkspaceTools.parse_env(~s({"KEY":"val"})) == %{"KEY" => "val"}
    end

    test "parses JSON array of KEY=VAL strings" do
      input = ~s(["DATABASE_URL=postgres://localhost/db", "REDIS_URL=redis://localhost"])
      assert WorkspaceTools.parse_env(input) == %{
        "DATABASE_URL" => "postgres://localhost/db",
        "REDIS_URL" => "redis://localhost"
      }
    end

    test "parses comma-separated KEY=VAL pairs" do
      assert WorkspaceTools.parse_env("FOO=bar,BAZ=qux") == %{"FOO" => "bar", "BAZ" => "qux"}
    end

    test "parses native list of KEY=VAL strings" do
      assert WorkspaceTools.parse_env(["FOO=bar", "BAZ=qux"]) == %{"FOO" => "bar", "BAZ" => "qux"}
    end

    test "returns empty map for garbage" do
      assert WorkspaceTools.parse_env("not-a-thing") == %{}
    end

    test "returns empty map for non-binary non-map" do
      assert WorkspaceTools.parse_env(42) == %{}
    end
  end

  describe "parse_volumes/1" do
    test "nil returns empty list" do
      assert WorkspaceTools.parse_volumes(nil) == []
    end

    test "passes through list" do
      assert WorkspaceTools.parse_volumes(["{data}:/var/lib/postgresql/data"]) == ["{data}:/var/lib/postgresql/data"]
    end

    test "parses JSON array" do
      input = ~s(["{data}:/var/lib/postgresql/data"])
      assert WorkspaceTools.parse_volumes(input) == ["{data}:/var/lib/postgresql/data"]
    end

    test "wraps single string in list" do
      assert WorkspaceTools.parse_volumes("{data}:/var/lib/postgresql/data") == ["{data}:/var/lib/postgresql/data"]
    end

    test "returns empty list for garbage" do
      assert WorkspaceTools.parse_volumes(42) == []
    end
  end

  describe "parse_ports/1" do
    test "nil returns empty list" do
      assert WorkspaceTools.parse_ports(nil) == []
    end

    test "integer port" do
      assert WorkspaceTools.parse_ports(3000) == ["3000"]
    end

    test "plain string port" do
      assert WorkspaceTools.parse_ports("3000") == ["3000"]
    end

    test "comma-separated ports" do
      assert WorkspaceTools.parse_ports("3000, 3001") == ["3000", "3001"]
    end

    test "JSON array string" do
      assert WorkspaceTools.parse_ports(~s(["3000", "3001"])) == ["3000", "3001"]
    end

    test "native list" do
      assert WorkspaceTools.parse_ports(["3000", "3001"]) == ["3000", "3001"]
    end

    test "host:container format extracts both numbers" do
      assert WorkspaceTools.parse_ports("3000:3000") == ["3000", "3000"]
    end

    test "garbage returns empty" do
      assert WorkspaceTools.parse_ports(%{}) == []
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

    test "do_update_config falls back to working_dir", %{agent_id: id} do
      result = WorkspaceTools.do_update_config(id, fn ws -> %{ws | name: "Fallback"} end, "ok")
      assert {:ok, _} = result
    end
  end
end
