defmodule Loopyard.ChatAgentTest do
  use ExUnit.Case

  # Every describe block's setup boots a ChatAgent via
  # Loopyard.TestHelpers.start_agent. Each setup gets a UNIQUE tmp_dir
  # so the WorkspaceGroup is per-test, not shared with siblings. Sharing
  # the cwd-derived workspace_id used to cause ServiceManager async_init
  # exits → :one_for_all rebuilds → flaky setup waits.
  @moduletag timeout: 10_000

  alias Loopyard.ChatAgent

  # Unique scratch dir per setup. Caller must File.rm_rf! in on_exit.
  defp scratch_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

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

  describe "stop_agent/1 on an already-dead pid" do
    # AgentBoot rollback calls stop_agent on agents that may be
    # mid-crash. Without an alive? guard, GenServer.stop waits up
    # to 5s for a noproc exit. Guard short-circuits for dead pids,
    # so rollback completes immediately.
    test "short-circuits and returns :ok quickly" do
      id = "stop-dead-#{:rand.uniform(1_000_000)}"

      # Register a doomed process that dies immediately. Registry
      # entry lingers briefly after the pid dies (Registry cleans
      # up via monitor, which is async).
      {:ok, pid} =
        Task.start(fn ->
          Registry.register(Loopyard.ChatAgentRegistry, id, nil)
          # Exit immediately so pid is dead but Registry may still
          # return it.
          :ok
        end)

      # Wait for the task to exit (Registry cleanup is async, so
      # the lookup may still return the now-dead pid).
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, _, _, _}, 500

      # Even if Registry still has the dead pid, stop_agent must
      # not block on a 5s GenServer.stop timeout.
      {us, result} = :timer.tc(fn -> ChatAgent.stop_agent(id) end)
      assert result == :ok
      assert us < 500_000, "stop_agent on dead pid took #{div(us, 1000)}ms (expected <500ms)"
    end

    test "returns :ok quickly when there is no registered pid" do
      id = "stop-unregistered-#{:rand.uniform(1_000_000)}"

      {us, result} = :timer.tc(fn -> ChatAgent.stop_agent(id) end)
      assert result == :ok
      assert us < 100_000, "stop_agent with no registered pid took #{div(us, 1000)}ms"
    end
  end

  describe "restart_session/1" do
    setup do
      tmp_dir = scratch_dir("restart-test")
      id = "restart-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} =
        Loopyard.TestHelpers.start_agent(
          id: id,
          name: "Restart Test",
          working_dir: tmp_dir,
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

      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{id: id, tmp_dir: tmp_dir}
    end

    test "restart_session preserves agent state and adds system message", %{id: id} do
      ChatAgent.subscribe(id)
      ChatAgent.subscribe()

      # Agent should be idle before restart
      state_before = ChatAgent.get_state(id)
      assert state_before.status == :idle

      ChatAgent.restart_session(id)

      # Should receive a system message about the restart
      assert_receive %Loopyard.Events.ChatAgentMessage.Message{
                       agent_id: ^id,
                       msg: %{role: :system, content: "CLI session restarted"}
                     },
                     5000

      # Agent should still be idle after restart
      state_after = ChatAgent.get_state(id)
      assert state_after.status == :idle
      assert state_after.name == "Restart Test"
      assert state_after.id == id
    end
  end

  describe "get_state/1" do
    setup do
      tmp_dir = scratch_dir("state-test")
      id = "state-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} =
        Loopyard.TestHelpers.start_agent(
          id: id,
          name: "State Test",
          working_dir: tmp_dir,
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

      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{id: id, tmp_dir: tmp_dir}
    end

    test "returns agent summary with all fields", %{id: id, tmp_dir: tmp_dir} do
      state = ChatAgent.get_state(id)

      assert state.id == id
      assert state.name == "State Test"
      assert state.working_dir == tmp_dir
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
        assert msg[:id] != nil,
               "Message missing :id — role: #{msg.role}, content: #{inspect(String.slice(msg.content || "", 0..30))}"
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
      tmp_dir = scratch_dir("timeout-test")
      id = "timeout-test-#{:rand.uniform(100_000)}"

      {:ok, pid} =
        Loopyard.TestHelpers.start_agent(
          id: id,
          name: "Timeout Test",
          working_dir: tmp_dir,
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

      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{id: id, pid: pid, tmp_dir: tmp_dir}
    end

    test "stale stream_timeout is ignored when agent is thinking on a new stream", %{
      id: id,
      pid: pid
    } do
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

      refute_receive %Loopyard.Events.ChatAgentMessage.Message{
                       agent_id: ^id,
                       msg: %{role: :error}
                     },
                     100
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
      @behaviour Loopyard.Agent.Backend

      use GenServer

      @impl Loopyard.Agent.Backend
      def start_session(_opts) do
        GenServer.start_link(__MODULE__, :ok)
      end

      @impl Loopyard.Agent.Backend
      def stream(_session, _prompt), do: []

      @impl Loopyard.Agent.Backend
      def stop(session) do
        if is_pid(session) and Process.alive?(session) do
          GenServer.stop(session, :normal, 1_000)
        end

        :ok
      end

      @impl Loopyard.Agent.Backend
      def session_alive?(session), do: is_pid(session) and Process.alive?(session)

      @impl Loopyard.Agent.Backend
      def session_id(_session), do: nil

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
      tmp_dir = scratch_dir("leak-test")
      id = "leak-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} =
        Loopyard.TestHelpers.start_agent(
          id: id,
          name: "Leak Test",
          working_dir: tmp_dir,
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

      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{id: id, tmp_dir: tmp_dir}
    end

    test "stopping agent kills the underlying OS process", %{id: id} do
      # Get the session PID from the agent
      [{pid, _}] = Registry.lookup(Loopyard.ChatAgentRegistry, id)
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
      [{pid, _}] = Registry.lookup(Loopyard.ChatAgentRegistry, id)
      %{session: session} = :sys.get_state(pid, 1_000)

      # Kill the session before stopping the agent
      Process.exit(session, :kill)
      Process.sleep(50)

      # Stop should not crash
      ChatAgent.stop_agent(id)
      Process.sleep(100)

      # Agent should be gone
      assert [] = Registry.lookup(Loopyard.ChatAgentRegistry, id)
    end
  end

  describe "message ordering and cap" do
    setup do
      tmp_dir = scratch_dir("msg-cap-test")
      id = "msg-cap-test-#{:rand.uniform(100_000)}"

      {:ok, _pid} =
        Loopyard.TestHelpers.start_agent(
          id: id,
          name: "Cap Test",
          working_dir: tmp_dir,
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

      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      %{id: id, tmp_dir: tmp_dir}
    end

    test "messages are returned in chronological order", %{id: id} do
      # Use append_message_ets to insert deterministically — send_message
      # spawns a CLI stream task that errors out and saves the message
      # eventually, requiring a sleep to wait for ETS to settle.
      # append_message_ets goes through the GenServer cast which is FIFO
      # with the subsequent get_state call.
      ChatAgent.append_message_ets(id, %{
        role: :user,
        content: "first",
        timestamp: DateTime.utc_now()
      })

      ChatAgent.append_message_ets(id, %{
        role: :user,
        content: "second",
        timestamp: DateTime.utc_now()
      })

      state = ChatAgent.get_state(id)
      user_msgs = Enum.filter(state.messages, &(&1.role == :user))
      contents = Enum.map(user_msgs, & &1.content)
      assert contents == ["first", "second"]
    end

    @tag timeout: 15_000
    test "messages are capped at 1000", %{id: id} do
      # Directly inject messages via the GenServer to avoid CLI overhead.
      # Use role: :user — :system triggers the auto-continue side effect
      # in handle_cast({:append_external_message, ...}) which casts
      # {:send_message, "Continue."} and would interleave "Continue."
      # user messages with the numbered ones. We're testing cap
      # behavior, not auto-continue semantics.
      [{pid, _}] = Registry.lookup(Loopyard.ChatAgentRegistry, id)

      for i <- 1..1050 do
        msg = %{role: :user, content: "msg-#{i}", timestamp: DateTime.utc_now()}
        GenServer.cast(pid, {:append_external_message, msg})
      end

      # Drain all 1050 casts before checking state. GenServer.call is
      # FIFO with prior casts, so this synchronization guarantees
      # every cast was processed. ChatAgent.get_state has a 500ms call
      # timeout that falls back to ETS — too tight when CI is busy
      # processing 1050 mailbox messages. Use a direct call with a
      # generous timeout instead.
      state = GenServer.call(pid, :get_state, 10_000)
      assert length(state.messages) <= 1000
      # Newest messages should be preserved (oldest trimmed)
      last = List.last(state.messages)
      assert last.content == "msg-1050"
    end
  end

  describe "build_system_prompt/2" do
    test "setup agent prompt stays under CLI argument limit" do
      prompt =
        ChatAgent.build_system_prompt("test-id", agent_type: "setup", bind_mount: "/tmp/project")

      assert String.length(prompt) <= 3500,
             "Setup prompt is #{String.length(prompt)} chars, max is 3500."
    end

    test "container agent prompt stays under limit" do
      workspace = %Loopyard.Workspace{
        name: "test-project",
        system_prompt: "This is a Rails app.",
        git_url: nil,
        branch: nil
      }

      prompt =
        ChatAgent.build_system_prompt("test-id",
          bind_mount: "/tmp/project",
          workspace_id: "abcd",
          workspace: workspace,
          agent_type: "coding"
        )

      assert String.length(prompt) <= 3500,
             "Container prompt is #{String.length(prompt)} chars, max is 3500."
    end

    test "container agent with service stays under limit" do
      workspace = %Loopyard.Workspace{
        name: "test-project",
        system_prompt: "Rails app with postgres.",
        git_url: nil,
        branch: nil
      }

      prompt =
        ChatAgent.build_system_prompt("test-id",
          bind_mount: "/tmp/project",
          workspace_id: "abcd",
          workspace: workspace,
          service_name: "postgres",
          agent_type: "coding"
        )

      assert String.length(prompt) <= 3500,
             "Full prompt is #{String.length(prompt)} chars, max is 3500."
    end
  end

  describe "remove_agent/1 is idempotent (state-machine guard)" do
    # The "remove → restart Claude → remove again" race used to
    # re-broadcast :chat_agent_status_changed for an already-destroying
    # agent, confusing watchers. With the StateMachine wired in,
    # calling remove_agent on an agent already in :destroying is a no-op.

    setup do
      id = "remove-idempotent-test-#{:rand.uniform(1_000_000)}"

      :ets.insert(
        :chat_agents,
        {id, %{id: id, name: "test", status: :idle, messages: [], workspace_id: nil}}
      )

      on_exit(fn -> :ets.delete(:chat_agents, id) end)
      %{id: id}
    end

    test "second remove on a :destroying agent doesn't re-broadcast",
         %{id: id} do
      ChatAgent.subscribe()

      # First call: :idle → :destroying → ETS delete. Both broadcasts
      # should land.
      ChatAgent.remove_agent(id)

      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :destroying}, 500
      assert_receive %Loopyard.Events.ChatAgent.Removed{id: ^id}, 500

      # Simulate the race: re-insert a :destroying entry as if another
      # viewer still had it cached, and call remove_agent again. The
      # StateMachine guard must detect this and skip re-broadcasting.
      :ets.insert(
        :chat_agents,
        {id, %{id: id, name: "test", status: :destroying, messages: [], workspace_id: nil}}
      )

      ChatAgent.remove_agent(id)

      refute_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :destroying}, 200
    end
  end

  describe "init_resume preserves durable fields" do
    # Regression: `init_resume` used to hand-list the fields it copied
    # from the saved ETS summary, so any field added to `summary/1`
    # (tokens, cost, model, turns, active_tool) silently reset to its
    # struct default on every resume. UI showed zero cost/tokens on an
    # agent mid-work after any supervisor restart.
    #
    # Guarantee under test: every field `summary/1` exposes survives a
    # resume round-trip via ETS. If someone adds a new summary field
    # without wiring it into the struct defaults, this test fails.

    setup do
      id = "resume-preserve-#{:rand.uniform(1_000_000)}"

      on_exit(fn ->
        try do
          ChatAgent.stop_agent(id)
        catch
          :exit, _ -> :ok
        end

        :ets.delete(:chat_agents, id)
      end)

      %{id: id}
    end

    test "resume rebuilds struct with tokens, cost, model, turns intact", %{id: id} do
      saved = %{
        id: id,
        name: "Resume Test",
        working_dir: File.cwd!(),
        bind_mount: nil,
        workspace_id: nil,
        started_at: ~U[2026-01-01 00:00:00Z],
        started_by: "test",
        last_activity_at: ~U[2026-01-01 00:05:00Z],
        status: :idle,
        messages: [],
        tool_calls: 7,
        errors: 1,
        service_name: nil,
        agent_type: "coding",
        model: "claude-opus-4-7",
        total_input_tokens: 12_345,
        total_output_tokens: 6_789,
        total_cache_read_tokens: 99_000,
        total_cost_usd: 1.234,
        active_tool: nil,
        turns: 42
      }

      :ets.insert(:chat_agents, {id, saved})

      tmp_dir = scratch_dir("resume-rebuild")
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      {:ok, _pid} =
        Loopyard.TestHelpers.start_agent(
          id: id,
          resume: true,
          working_dir: tmp_dir,
          started_by: "test",
          backend: Loopyard.Agent.Backend.Fake
        )

      live = ChatAgent.get_state(id)

      # Every durable summary field survives resume.
      assert live.model == "claude-opus-4-7"
      assert live.total_input_tokens == 12_345
      assert live.total_output_tokens == 6_789
      assert live.total_cache_read_tokens == 99_000
      assert live.total_cost_usd == 1.234
      assert live.turns == 42
      assert live.tool_calls == 7
      assert live.errors == 1
      assert live.agent_type == "coding"
      assert live.name == "Resume Test"
      assert live.started_by == "test"
      assert live.started_at == ~U[2026-01-01 00:00:00Z]
    end

    test "resume preserves message order across a subsequent append", %{id: id} do
      # Summary stores messages oldest-first; internal state stores them
      # newest-first. An earlier bug used the saved display-order list
      # as the internal list, so post-resume appends reversed the older
      # messages. This asserts order is stable end-to-end.
      msgs = [
        %{id: "a", role: :user, content: "first", timestamp: ~U[2026-01-01 00:00:00Z]},
        %{id: "b", role: :assistant, content: "second", timestamp: ~U[2026-01-01 00:01:00Z]},
        %{id: "c", role: :user, content: "third", timestamp: ~U[2026-01-01 00:02:00Z]}
      ]

      saved = %{
        id: id,
        name: "Order Test",
        working_dir: File.cwd!(),
        bind_mount: nil,
        workspace_id: nil,
        started_at: ~U[2026-01-01 00:00:00Z],
        started_by: "test",
        last_activity_at: ~U[2026-01-01 00:00:00Z],
        status: :idle,
        messages: msgs,
        tool_calls: 0,
        errors: 0,
        service_name: nil,
        agent_type: "coding",
        model: nil,
        total_input_tokens: 0,
        total_output_tokens: 0,
        total_cache_read_tokens: 0,
        total_cost_usd: 0.0,
        active_tool: nil,
        turns: 0
      }

      :ets.insert(:chat_agents, {id, saved})

      tmp_dir = scratch_dir("resume-order")
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      {:ok, pid} =
        Loopyard.TestHelpers.start_agent(
          id: id,
          resume: true,
          working_dir: tmp_dir,
          started_by: "test",
          backend: Loopyard.Agent.Backend.Fake
        )

      # Force an external append (doesn't need the CLI) so we exercise
      # the "append on top of resumed state" path.
      # Use :user (not :system) so we don't trigger the idle→auto-continue
      # cast that appends "Continue." and skews the ordering assertion.
      new_msg = %{id: "d", role: :user, content: "fourth", timestamp: ~U[2026-01-01 00:03:00Z]}
      GenServer.cast(pid, {:append_external_message, new_msg})
      Process.sleep(50)

      live = ChatAgent.get_state(id)
      contents = Enum.map(live.messages, & &1.content)
      assert contents == ["first", "second", "third", "fourth"]
    end
  end
end
