defmodule BoomLooper.ChatAgent.ToolLoopTest do
  @moduledoc """
  Loop-detection for tool calls (agent-sanity follow-up).

  Agents occasionally get stuck calling the same tool with the same
  input repeatedly: grep for a nonexistent string, retry the same
  failing docker command, etc. Without detection the user watches
  tokens burn while the agent grinds, and the only signal is a long
  flat tool-call log.

  `maybe_detect_tool_loop/4` fingerprints `{tool_name, input}`,
  tracks the consecutive repeat count, and at
  `@tool_loop_threshold` (5) appends a visible system message
  + fires `[:boom_looper, :agent, :tool_loop_detected]` telemetry.
  One-shot per threshold crossing. The counter resets on
  stream_done (turn boundary) so warnings don't accumulate across
  unrelated turns.

  Tests:
    1. 5 identical calls in a row → warning appears + telemetry fires.
    2. 4 identical calls → no warning (under threshold).
    3. Call variation (same tool, different input) resets counter.
    4. stream_done resets `last_tool_call` so the next turn can
       re-trigger.
    5. Repeated calls past threshold don't duplicate the warning
       (one-shot).
  """

  use ExUnit.Case, async: false

  alias BoomLooper.ChatAgent
  alias BoomLooper.Agent.Event
  alias BoomLooper.TestSupport.RecordingBackend

  @moduletag timeout: 10_000

  setup do
    RecordingBackend.reset()
    id = "tool-loop-test-#{:rand.uniform(100_000)}"

    {:ok, _pid} =
      BoomLooper.TestHelpers.start_agent(
        id: id,
        name: "Tool Loop Test",
        working_dir: File.cwd!(),
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

      Process.sleep(20)
    end)

    %{id: id}
  end

  defp agent_pid(id) do
    case Registry.lookup(BoomLooper.ChatAgentRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp fire_tool_call(pid, id, ref, tool_name, input) do
    send(pid, {:stream_event, id, ref, %Event.ToolCall{name: tool_name, input: input}})
  end

  defp install_ref(pid) do
    ref = make_ref()
    :sys.replace_state(pid, fn s -> %{s | stream_ref: ref} end)
    ref
  end

  defp loop_warn_count(state) do
    Enum.count(state.messages, fn m ->
      m.role == :system and String.contains?(m.content || "", "retry loop")
    end)
  end

  describe "tool-call loop detection" do
    test "5 identical calls in a row → warning + telemetry fires", %{id: id} do
      pid = agent_pid(id)
      ref = install_ref(pid)

      parent = self()
      handler_id = "loop-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:boom_looper, :agent, :tool_loop_detected],
        fn _event, measurements, meta, _cfg ->
          send(parent, {:loop_detected, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      for _ <- 1..5 do
        fire_tool_call(pid, id, ref, "grep", %{pattern: "foo"})
      end

      _ = :sys.get_state(pid)

      assert_receive {:loop_detected, measurements, meta}, 500
      assert measurements.consecutive == 5
      assert meta.tool == "grep"
      assert meta.agent_id == id

      state = :sys.get_state(pid)
      assert loop_warn_count(state) == 1
    end

    test "4 identical calls in a row → no warning (under threshold)", %{id: id} do
      pid = agent_pid(id)
      ref = install_ref(pid)

      for _ <- 1..4 do
        fire_tool_call(pid, id, ref, "grep", %{pattern: "foo"})
      end

      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)

      assert loop_warn_count(state) == 0
    end

    test "call variation resets the counter", %{id: id} do
      pid = agent_pid(id)
      ref = install_ref(pid)

      # 3 identical, then different, then 3 more identical.
      for _ <- 1..3, do: fire_tool_call(pid, id, ref, "grep", %{pattern: "foo"})
      fire_tool_call(pid, id, ref, "grep", %{pattern: "bar"})
      for _ <- 1..3, do: fire_tool_call(pid, id, ref, "grep", %{pattern: "foo"})

      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)

      # Neither streak reached 5.
      assert loop_warn_count(state) == 0
    end

    test "stream_done resets last_tool_call so next turn can re-trigger", %{id: id} do
      pid = agent_pid(id)
      ref = install_ref(pid)

      for _ <- 1..5, do: fire_tool_call(pid, id, ref, "grep", %{pattern: "foo"})
      _ = :sys.get_state(pid)
      send(pid, {:stream_done, id, ref})
      _ = :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert state.last_tool_call == nil
    end

    test "calls past threshold don't duplicate the warning", %{id: id} do
      pid = agent_pid(id)
      ref = install_ref(pid)

      for _ <- 1..10, do: fire_tool_call(pid, id, ref, "grep", %{pattern: "foo"})
      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)

      # One-shot per threshold crossing.
      assert loop_warn_count(state) == 1
    end
  end
end
