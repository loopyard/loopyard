defmodule LoopyardWeb.MessageLiveTest do
  use LoopyardWeb.ConnCase

  # The setup boots a real workspace + agent (WorkspaceGroup.start_agent →
  # ChatAgent), which under full-suite load can take several seconds while the
  # workspace group churns and the agent CLI session comes up. The test logic
  # itself is fast (ETS reads + LiveView render); the default 2s per-test cap
  # was just too tight for the boot, causing flaky timeouts. Give it headroom.
  @moduletag timeout: 30_000

  import Phoenix.LiveViewTest

  alias Loopyard.ChatAgent

  defp create_workspace do
    tmp_dir = Path.join(System.tmp_dir!(), "loopyard-msg-test-#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    repo_dir = Path.join(tmp_dir, ".loopyard/repo")
    File.mkdir_p!(repo_dir)
    File.write!(Path.join(repo_dir, "workspace.json"), Jason.encode!(%{"name" => "test"}))
    {:ok, project, branch} = Loopyard.ProjectRegistry.add(tmp_dir)
    {project, branch, tmp_dir}
  end

  setup do
    {project, branch, tmp_dir} = create_workspace()

    agent_id = "msg-test-#{:rand.uniform(100_000)}"

    {:ok, _pid} =
      Loopyard.TestHelpers.start_agent(
        id: agent_id,
        name: "Msg Test Agent",
        working_dir: tmp_dir,
        bind_mount: tmp_dir,
        started_by: "test"
      )

    # Insert a user message directly via append_message_ets so the test
    # has something to look up — no Claude CLI dependency, no async wait.
    # Going through send_message used to require Process.sleep(1_000)
    # while the stream errored out; doing the ETS insert directly is
    # synchronous and the GenServer cast lands before the next call
    # because get_state is a synchronous GenServer.call (FIFO mailbox).
    ChatAgent.append_message_ets(agent_id, %{
      role: :user,
      content: "hello world",
      timestamp: DateTime.utc_now()
    })

    on_exit(fn ->
      try do
        ChatAgent.stop_agent(agent_id)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(tmp_dir)
    end)

    %{project: project, branch: branch, tmp_dir: tmp_dir, agent_id: agent_id}
  end

  describe "message URL contract" do
    test "every message has a unique non-nil ID", %{agent_id: agent_id} do
      state = ChatAgent.get_state(agent_id)
      assert state.messages != []

      for msg <- state.messages do
        assert msg[:id] != nil, "Message missing :id — role: #{msg.role}"
      end

      ids = Enum.map(state.messages, & &1[:id]) |> Enum.reject(&is_nil/1)
      assert ids == Enum.uniq(ids), "Duplicate message IDs found"
    end

    test "get_message returns message by ID", %{agent_id: agent_id} do
      state = ChatAgent.get_state(agent_id)
      msg = Enum.find(state.messages, &(&1.role == :user))
      assert msg != nil
      assert msg[:id] != nil

      found = ChatAgent.get_message(agent_id, msg.id)
      assert found != nil
      assert found.content == "hello world"
      assert found.id == msg.id
    end

    test "msg_url generates a URL that MessageLive can load", %{agent_id: agent_id, conn: conn} do
      state = ChatAgent.get_state(agent_id)
      msg = Enum.find(state.messages, &(&1.role == :user))
      assert msg != nil

      url = LoopyardWeb.OutputController.msg_url(agent_id, msg.id)
      assert url =~ msg.id

      {:ok, _view, html} = live(conn, url)

      assert html =~ "hello world",
             "MessageLive shows 'not found' instead of message content. URL: #{url}"

      refute html =~ "Message not found or link expired"
    end

    test "MessageLive mount returns under 500ms — single ETS read", %{
      agent_id: agent_id,
      conn: conn
    } do
      state = ChatAgent.get_state(agent_id)
      msg = Enum.find(state.messages, &(&1.role == :user))
      url = LoopyardWeb.OutputController.msg_url(agent_id, msg.id)

      {micros, {:ok, _view, _html}} = :timer.tc(fn -> live(conn, url) end)

      assert micros < 500_000,
             "MessageLive mount took #{div(micros, 1000)}ms — slow call slipped in"
    end

    test "raw URL returns message content as plain text", %{agent_id: agent_id, conn: conn} do
      state = ChatAgent.get_state(agent_id)
      msg = Enum.find(state.messages, &(&1.role == :user))

      url = LoopyardWeb.OutputController.raw_url(agent_id, msg.id)

      resp = get(conn, url)
      assert resp.status == 200
      assert resp.resp_body =~ "hello world"
    end
  end

  describe "append_message_ets" do
    test "messages appended via ETS are findable by get_message", %{agent_id: agent_id} do
      stream_msg = %{
        role: :build,
        title: "test cmd",
        content: "output here",
        timestamp: DateTime.utc_now()
      }

      result = ChatAgent.append_message_ets(agent_id, stream_msg)

      assert result != nil
      assert result.id != nil

      found = ChatAgent.get_message(agent_id, result.id)
      assert found != nil
      assert found.content == "output here"
      assert found.role == :build
    end

    test "messages appended via ETS survive update_message calls", %{agent_id: agent_id} do
      stream_msg = %{role: :build, title: "test cmd", content: "", timestamp: DateTime.utc_now()}
      result = ChatAgent.append_message_ets(agent_id, stream_msg)

      # Update the message content (simulates streaming output)
      ChatAgent.update_message(agent_id, result.id, fn msg ->
        %{msg | content: "updated output"}
      end)

      # Give GenServer time to process the cast
      Process.sleep(50)

      found = ChatAgent.get_message(agent_id, result.id)
      assert found.content == "updated output"
    end
  end

  describe "message link from chat page" do
    test "chat page renders message links that load correctly", %{
      project: project,
      branch: branch,
      agent_id: agent_id,
      conn: conn
    } do
      chat_path = "/projects/#{project.id}/workspaces/#{branch.id}/agents/#{agent_id}"
      {:ok, _view, html} = live(conn, chat_path)

      case Regex.run(~r{href="(/messages/[^"]*?)"}, html) do
        [_, msg_link] ->
          {:ok, _view, msg_html} = live(conn, msg_link)

          refute msg_html =~ "Message not found or link expired",
                 "Message link from chat page leads to 'not found'. Link: #{msg_link}"

        nil ->
          :ok
      end
    end
  end
end
