defmodule BoomLooper.ChatAgentTest do
  use ExUnit.Case

  alias BoomLooper.ChatAgent

  describe "list_agents/0" do
    test "returns a list" do
      assert is_list(ChatAgent.list_agents())
    end
  end

  describe "subscribe/0" do
    test "subscribes to the global chat agents topic" do
      assert :ok = ChatAgent.subscribe()
    end
  end

  describe "subscribe/1 and unsubscribe/1" do
    test "subscribes and unsubscribes to a specific agent" do
      assert :ok = ChatAgent.subscribe("test-id")
      assert :ok = ChatAgent.unsubscribe("test-id")
    end
  end

  describe "restart_session/1" do
    setup do
      id = "restart-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "Restart Test",
          working_dir: File.cwd!(),
          started_by: "test"
        )

      on_exit(fn ->
        try do
          ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        Process.sleep(50)
      end)

      %{id: id}
    end

    test "restart_session preserves agent state and adds system message", %{id: id} do
      ChatAgent.subscribe(id)
      ChatAgent.subscribe()

      # Agent should be idle before restart
      state_before = ChatAgent.get_state(id)
      assert state_before.status == :idle

      ChatAgent.restart_session(id)

      # Should receive a system message about the restart
      assert_receive {:chat_message, ^id, %{role: :system, content: "CLI session restarted"}}, 5000

      # Agent should still be idle after restart
      state_after = ChatAgent.get_state(id)
      assert state_after.status == :idle
      assert state_after.name == "Restart Test"
      assert state_after.id == id
    end
  end

  describe "get_state/1" do
    setup do
      id = "state-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "State Test",
          working_dir: File.cwd!(),
          started_by: "test"
        )

      on_exit(fn ->
        try do
          ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        Process.sleep(50)
      end)

      %{id: id}
    end

    test "returns agent summary with all fields", %{id: id} do
      state = ChatAgent.get_state(id)

      assert state.id == id
      assert state.name == "State Test"
      assert state.working_dir == File.cwd!()
      assert state.started_by == "test"
      assert state.status == :idle
      assert state.messages == []
      assert state.tool_calls == 0
      assert state.errors == 0
      assert %DateTime{} = state.started_at
      assert %DateTime{} = state.last_activity_at
    end

    test "messages have unique IDs after send", %{id: id} do
      ChatAgent.send_message(id, "hello")
      Process.sleep(200)

      state = ChatAgent.get_state(id)
      # Should have at least the user message
      user_msgs = Enum.filter(state.messages, &(&1.role == :user))
      assert length(user_msgs) >= 1

      # Every message must have an :id
      for msg <- state.messages do
        assert msg[:id] != nil, "Message missing :id — role: #{msg.role}, content: #{inspect(String.slice(msg.content || "", 0..30))}"
      end

      # IDs must be unique
      ids = Enum.map(state.messages, & &1[:id]) |> Enum.reject(&is_nil/1)
      assert ids == Enum.uniq(ids), "Duplicate message IDs found"
    end

    test "get_message returns message by ID", %{id: id} do
      ChatAgent.send_message(id, "test lookup")
      Process.sleep(200)

      state = ChatAgent.get_state(id)
      msg = Enum.find(state.messages, &(&1.role == :user))

      assert msg[:id] != nil
      found = ChatAgent.get_message(id, msg.id)
      assert found != nil
      assert found.content == "test lookup"
    end

    test "get_message returns nil for unknown ID", %{id: id} do
      assert ChatAgent.get_message(id, "nonexistent") == nil
    end
  end

  describe "stream_timeout with ref" do
    setup do
      id = "timeout-test-#{:rand.uniform(100_000)}"

      {:ok, pid} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "Timeout Test",
          working_dir: File.cwd!(),
          started_by: "test"
        )

      on_exit(fn ->
        try do
          ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        Process.sleep(50)
      end)

      %{id: id, pid: pid}
    end

    test "stale stream_timeout is ignored when agent is thinking on a new stream", %{id: id, pid: pid} do
      ChatAgent.subscribe(id)

      # Simulate: a stale timeout from a previous stream fires while agent is thinking
      # First, put the agent into thinking state with a current stream_ref
      _current_ref = make_ref()
      stale_ref = make_ref()

      # Send a stale timeout (wrong ref) — should be ignored
      send(pid, {:stream_timeout, id, stale_ref})
      Process.sleep(50)

      state = ChatAgent.get_state(id)
      # Agent should still be idle (not errored), because the stale timeout was ignored
      assert state.status == :idle
      refute_receive {:chat_message, ^id, %{role: :error}}, 100
    end

    test "legacy stream_timeout without ref is ignored", %{id: id, pid: pid} do
      send(pid, {:stream_timeout, id})
      Process.sleep(50)

      state = ChatAgent.get_state(id)
      assert state.status == :idle
    end
  end

  describe "terminate kills OS process (process leak fix)" do
    defmodule PortAdapter do
      @moduledoc """
      A fake adapter GenServer that holds a Port, mimicking the structure
      that get_session_os_pid walks: session pid → linked child → %{port: port}.
      """
      use GenServer

      def start_link(cmd) do
        GenServer.start_link(__MODULE__, cmd)
      end

      def get_os_pid(adapter) do
        GenServer.call(adapter, :os_pid)
      end

      @impl true
      def init(cmd) do
        port = Port.open({:spawn, cmd}, [:binary, :exit_status])
        {:os_pid, os_pid} = Port.info(port, :os_pid)
        {:ok, %{port: port, os_pid: os_pid}}
      end

      @impl true
      def handle_call(:os_pid, _from, state) do
        {:reply, state.os_pid, state}
      end

      @impl true
      def handle_info({_port, {:exit_status, _}}, state), do: {:noreply, state}
    end

    defmodule PortBackend do
      @moduledoc """
      Test backend that spawns a real OS process (sleep) via a linked adapter.
      The session is a GenServer that links to the adapter — same topology as ClaudeCode.
      """
      @behaviour BoomLooper.Agent.Backend

      use GenServer

      @impl BoomLooper.Agent.Backend
      def start_session(_opts) do
        GenServer.start_link(__MODULE__, :ok)
      end

      @impl BoomLooper.Agent.Backend
      def stream(_session, _prompt), do: []

      @impl BoomLooper.Agent.Backend
      def stop(session) do
        if is_pid(session) and Process.alive?(session) do
          GenServer.stop(session, :normal, 1_000)
        end
        :ok
      end

      @impl BoomLooper.Agent.Backend
      def session_alive?(session), do: is_pid(session) and Process.alive?(session)

      # GenServer that links to a PortAdapter child
      @impl GenServer
      def init(:ok) do
        {:ok, adapter} = PortAdapter.start_link("sleep 999")
        Process.link(adapter)
        os_pid = PortAdapter.get_os_pid(adapter)
        {:ok, %{adapter: adapter, os_pid: os_pid}}
      end

      @impl GenServer
      def handle_call(:os_pid, _from, state) do
        {:reply, state.os_pid, state}
      end
    end

    setup do
      id = "leak-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "Leak Test",
          working_dir: File.cwd!(),
          started_by: "test",
          backend: PortBackend
        )

      on_exit(fn ->
        try do
          ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        Process.sleep(50)
      end)

      %{id: id}
    end

    test "stopping agent kills the underlying OS process", %{id: id} do
      # Get the session PID from the agent
      [{pid, _}] = Registry.lookup(BoomLooper.ChatAgentRegistry, id)
      %{session: session} = :sys.get_state(pid, 1_000)

      # Get the OS PID of the sleep process through the session
      os_pid = GenServer.call(session, :os_pid)
      assert is_integer(os_pid)

      # Verify the OS process is alive
      assert {_, 0} = System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true)

      # Stop the agent — this triggers terminate/2
      ChatAgent.stop_agent(id)
      Process.sleep(200)

      # The OS process should be dead now
      {_, exit_code} = System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true)
      assert exit_code != 0, "OS process #{os_pid} still alive after agent stop — process leak!"
    end

    test "terminate handles already-dead session gracefully", %{id: id} do
      [{pid, _}] = Registry.lookup(BoomLooper.ChatAgentRegistry, id)
      %{session: session} = :sys.get_state(pid, 1_000)

      # Kill the session before stopping the agent
      Process.exit(session, :kill)
      Process.sleep(50)

      # Stop should not crash
      ChatAgent.stop_agent(id)
      Process.sleep(100)

      # Agent should be gone
      assert [] = Registry.lookup(BoomLooper.ChatAgentRegistry, id)
    end
  end

  describe "message ordering and cap" do
    setup do
      id = "msg-cap-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} =
        BoomLooper.TestHelpers.start_agent(
          id: id,
          name: "Cap Test",
          working_dir: File.cwd!(),
          started_by: "test"
        )

      on_exit(fn ->
        try do
          ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        Process.sleep(50)
      end)

      %{id: id}
    end

    @tag timeout: 10_000
    test "messages are returned in chronological order", %{id: id} do
      ChatAgent.send_message(id, "first")
      Process.sleep(500)
      ChatAgent.send_message(id, "second")
      Process.sleep(500)

      state = ChatAgent.get_state(id)
      user_msgs = Enum.filter(state.messages, &(&1.role == :user))
      contents = Enum.map(user_msgs, & &1.content)
      assert contents == ["first", "second"]
    end

    @tag timeout: 10_000
    test "messages are capped at 1000", %{id: id} do
      # Directly inject messages via the GenServer to avoid CLI overhead
      [{pid, _}] = Registry.lookup(BoomLooper.ChatAgentRegistry, id)

      for i <- 1..1050 do
        msg = %{role: :system, content: "msg-#{i}", timestamp: DateTime.utc_now()}
        GenServer.cast(pid, {:append_external_message, msg})
      end

      Process.sleep(200)
      state = ChatAgent.get_state(id)
      assert length(state.messages) <= 1000
      # Newest messages should be preserved (oldest trimmed)
      last = List.last(state.messages)
      assert last.content == "msg-1050"
    end
  end

  describe "build_system_prompt/6" do
    test "setup agent prompt stays under CLI argument limit" do
      prompt = ChatAgent.build_system_prompt("test-id", "/tmp/project", nil, nil, nil)
      assert String.length(prompt) <= 2000,
        "Setup prompt is #{String.length(prompt)} chars, max is 2000. Move content to priv/prompts/ or CLAUDE.md."
    end

    test "container agent prompt stays under limit" do
      workspace = %BoomLooper.Workspace{
        name: "test-project",
        system_prompt: "This is a Rails app.",
        git_url: nil,
        branch: nil
      }

      prompt = ChatAgent.build_system_prompt("test-id", "/tmp/project", "abcd", workspace, nil)
      assert String.length(prompt) <= 2000,
        "Container prompt is #{String.length(prompt)} chars, max is 2000."
    end

    test "container agent with service stays under limit" do
      workspace = %BoomLooper.Workspace{
        name: "test-project",
        system_prompt: "Rails app with postgres.",
        git_url: nil,
        branch: nil
      }

      prompt = ChatAgent.build_system_prompt("test-id", "/tmp/project", "abcd", workspace, "postgres")
      assert String.length(prompt) <= 2000,
        "Full prompt is #{String.length(prompt)} chars, max is 2000."
    end
  end
end
