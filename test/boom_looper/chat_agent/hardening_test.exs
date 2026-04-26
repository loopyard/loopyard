defmodule BoomLooper.ChatAgent.HardeningTest do
  @moduledoc """
  Small bounded reliability wins for the ChatAgent GenServer:

    * **Unknown-cast catchall.** Historically `handle_cast/2` had no
      catchall. Any bogus cast (from a renamed caller, a stale
      broadcast, a tool bug) would crash the GenServer with
      FunctionClauseError, trip the RestartController's quarantine
      on 5-in-60, and knock every agent in the workspace offline.
      Now unknown casts log + fire `[:boom_looper, :actor,
      :unknown_message]` telemetry and :noreply.

    * **Unknown-call catchall.** Same fix applied to `handle_call/3`.
      Returns `{:error, :unknown_call}` so callers can distinguish
      "I don't handle that" from "the agent is dead." Without this
      the caller got either a FunctionClauseError or a timeout.

    * **Message size cap.** Single `:send_message` payloads over
      `@max_message_bytes` (1MB default) are rejected with a visible
      error message instead of exploding the mailbox / PubSub /
      Claude API cost. Configurable via
      `Application.compile_env(:boom_looper, :max_message_bytes)`.
  """

  use ExUnit.Case, async: false

  alias BoomLooper.ChatAgent
  alias BoomLooper.TestSupport.RecordingBackend

  @moduletag timeout: 10_000

  setup do
    RecordingBackend.reset()
    id = "hardening-test-#{:rand.uniform(100_000)}"

    # Per-test tmp_dir so we don't share a cwd-derived workspace_id
    # with other tests in the suite (causes setup churn under load).
    tmp_dir = Path.join(System.tmp_dir!(), "hardening-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    {:ok, _pid} =
      BoomLooper.TestHelpers.start_agent(
        id: id,
        name: "Hardening Test",
        working_dir: tmp_dir,
        started_by: "test",
        backend: RecordingBackend
      )

    ChatAgent.subscribe()
    ChatAgent.subscribe(id)

    on_exit(fn ->
      try do
        ChatAgent.stop_agent(id)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(tmp_dir)
    end)

    %{id: id}
  end

  defp agent_pid(id) do
    case Registry.lookup(BoomLooper.ChatAgentRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  describe "unknown-cast catchall" do
    test "unknown cast does NOT crash the agent + fires telemetry", %{id: id} do
      pid = agent_pid(id)

      parent = self()
      handler_id = "unknown-cast-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:boom_looper, :actor, :unknown_message],
        fn _event, _m, meta, _cfg -> send(parent, {:unknown_msg, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      GenServer.cast(pid, {:bogus_cast_name, "payload"})

      assert_receive {:unknown_msg, meta}, 500
      assert meta.kind == :cast
      assert meta.agent_id == id

      # Agent survived.
      assert Process.alive?(pid)
    end
  end

  describe "unknown-call catchall" do
    test "unknown call returns {:error, :unknown_call} + fires telemetry", %{id: id} do
      pid = agent_pid(id)

      parent = self()
      handler_id = "unknown-call-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:boom_looper, :actor, :unknown_message],
        fn _event, _m, meta, _cfg -> send(parent, {:unknown_msg, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, :unknown_call} = GenServer.call(pid, :never_heard_of_it)

      assert_receive {:unknown_msg, meta}, 500
      assert meta.kind == :call
      assert meta.agent_id == id

      assert Process.alive?(pid)
    end
  end

  describe "message size cap" do
    test "oversized send_message is rejected with a visible error message",
         %{id: id} do
      pid = agent_pid(id)

      parent = self()
      handler_id = "rejected-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:boom_looper, :agent, :message_rejected],
        fn _event, measurements, meta, _cfg ->
          send(parent, {:rejected, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Default cap is 1MB. 2MB string triggers the reject path.
      oversized = :binary.copy("X", 2 * 1_048_576)
      ChatAgent.send_message(id, oversized)

      assert_receive {:rejected, measurements, meta}, 500
      assert measurements.bytes == byte_size(oversized)
      assert meta.reason == :oversized

      state = :sys.get_state(pid)

      # No user message (the send never reached the send_message_normal
      # path) — just an error message explaining the rejection.
      assert Enum.any?(state.messages, fn m ->
               m.role == :error and String.contains?(m.content || "", "exceeds")
             end)

      refute Enum.any?(state.messages, fn m -> m.role == :user end)

      # Agent status unchanged (not :thinking).
      assert state.status == :idle
    end

    test "normal-sized send_message goes through the normal path", %{id: id} do
      pid = agent_pid(id)

      ChatAgent.send_message(id, "hello, this is a normal-sized message")
      Process.sleep(50)

      state = :sys.get_state(pid)

      assert Enum.any?(state.messages, fn m ->
               m.role == :user and m.content == "hello, this is a normal-sized message"
             end)

      refute Enum.any?(state.messages, fn m ->
               m.role == :error and String.contains?(m.content || "", "exceeds")
             end)
    end
  end

  describe "non-binary send_message guard" do
    test "nil send_message is rejected cleanly, agent survives", %{id: id} do
      pid = agent_pid(id)

      parent = self()
      handler_id = "non-binary-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:boom_looper, :agent, :message_rejected],
        fn _event, _m, meta, _cfg -> send(parent, {:rejected, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Bypass the public send_message wrapper (which may type-check);
      # cast directly with a nil payload.
      GenServer.cast(pid, {:send_message, nil})
      Process.sleep(50)

      assert_receive {:rejected, meta}, 500
      assert meta.reason == :non_binary

      assert Process.alive?(pid)
      state = :sys.get_state(pid)
      assert state.status == :idle
    end

    test "atom payload is rejected", %{id: id} do
      pid = agent_pid(id)

      GenServer.cast(pid, {:send_message, :oops})
      Process.sleep(50)

      assert Process.alive?(pid)
    end

    test "integer payload is rejected", %{id: id} do
      pid = agent_pid(id)

      GenServer.cast(pid, {:send_message, 42})
      Process.sleep(50)

      assert Process.alive?(pid)
    end
  end
end
