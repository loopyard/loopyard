defmodule Loopyard.ChatAgent.ContextWindowTest do
  @moduledoc """
  Surface #18 of plans/agent-sanity.md.

  Claude has a finite context window. When full, the CLI silently
  drops earliest turns — the agent loses context without surfacing
  any signal to the user.

  This surface computes utilization (input_tokens + cache_read_tokens
  divided by the model's published window size) on every
  `%Event.SessionResult{}` and surfaces it two ways:

    1. `state.context_utilization` (float 0.0–1.0) + `summary/1` →
       UI can render a progress bar.
    2. When utilization crosses the 85% threshold, append an inline
       `⚠ Context window N% full` system message (one-shot per turn
       via `context_warning_sent` gate; cleared on stream_done so the
       warning re-fires on subsequent turns if utilization stays
       high).

  Auto-compaction on threshold is NOT implemented yet — the SDK
  doesn't expose a programmatic `/compact` API. Scope stays at
  "make the user aware" so they can start a fresh agent or run
  /clear themselves.
  """

  use ExUnit.Case, async: false

  alias Loopyard.ChatAgent
  alias Loopyard.Agent.Event
  alias Loopyard.TestSupport.RecordingBackend

  @moduletag timeout: 10_000

  setup do
    RecordingBackend.reset()
    id = "context-window-test-#{:rand.uniform(100_000)}"

    {:ok, _pid} =
      Loopyard.TestHelpers.start_agent(
        id: id,
        name: "Context Window Test",
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
    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  describe "surface #18: context window utilization" do
    test "SessionResult populates context_utilization based on model's window", %{id: id} do
      pid = agent_pid(id)
      ref = make_ref()
      :sys.replace_state(pid, fn s -> %{s | stream_ref: ref} end)

      # Sonnet is 200K window. 100K input_tokens + 0 cache = 50%.
      send(
        pid,
        {:stream_event, id, ref,
         %Event.SessionResult{
           model: "claude-sonnet-4-6",
           input_tokens: 100_000,
           output_tokens: 1_000,
           cache_read_tokens: 0,
           cost_usd: 0.05,
           duration_ms: 2_000,
           num_turns: 1
         }}
      )

      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)

      assert_in_delta state.context_utilization, 0.5, 0.01
      # ETS summary mirrors it.
      [{^id, summary}] = :ets.lookup(:chat_agents, id)
      assert_in_delta summary.context_utilization, 0.5, 0.01
    end

    test "cache_read_tokens count toward utilization", %{id: id} do
      pid = agent_pid(id)
      ref = make_ref()
      :sys.replace_state(pid, fn s -> %{s | stream_ref: ref} end)

      # Opus is 1M window. 400K input + 500K cache = 900K / 1M = 90%.
      send(
        pid,
        {:stream_event, id, ref,
         %Event.SessionResult{
           model: "claude-opus-4-7",
           input_tokens: 400_000,
           output_tokens: 1_000,
           cache_read_tokens: 500_000,
           cost_usd: 0.1,
           duration_ms: 2_000,
           num_turns: 1
         }}
      )

      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)

      assert_in_delta state.context_utilization, 0.9, 0.01
    end

    test "crossing 85% threshold sets the one-shot warning flag (telemetry only, no inline UI)",
         %{id: id} do
      # The implementation deliberately doesn't append a user-facing
      # message — the auto-restart handles real exhaustion silently.
      # The contract here is the `context_warning_sent` flag (one-shot
      # per turn) plus the telemetry event, which ops dashboards read.
      :telemetry.attach(
        "ctx-warn-test-#{:erlang.unique_integer([:positive])}",
        [:loopyard, :agent, :context_warning],
        fn _event, measurements, meta, parent ->
          send(parent, {:context_warning, measurements, meta})
        end,
        self()
      )

      pid = agent_pid(id)
      ref = make_ref()
      :sys.replace_state(pid, fn s -> %{s | stream_ref: ref} end)

      # 180K / 200K = 90% on Sonnet.
      send(
        pid,
        {:stream_event, id, ref,
         %Event.SessionResult{
           model: "claude-sonnet-4-6",
           input_tokens: 180_000,
           output_tokens: 100,
           cache_read_tokens: 0,
           cost_usd: 0.05,
           duration_ms: 1_000,
           num_turns: 1
         }}
      )

      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)

      assert state.context_warning_sent == true
      assert_received {:context_warning, %{utilization: util}, _meta}
      assert util >= 0.85

      # Second high-utilization SessionResult on the same turn should
      # NOT re-fire telemetry (one-shot until stream_done clears the flag).
      send(
        pid,
        {:stream_event, id, ref,
         %Event.SessionResult{
           model: "claude-sonnet-4-6",
           input_tokens: 190_000,
           output_tokens: 100,
           cache_read_tokens: 0,
           cost_usd: 0.05,
           duration_ms: 1_000,
           num_turns: 2
         }}
      )

      _ = :sys.get_state(pid)
      refute_received {:context_warning, _, _}
    end

    test "stream_done resets context_warning_sent so the warning can re-fire next turn",
         %{id: id} do
      pid = agent_pid(id)
      ref = make_ref()

      :sys.replace_state(pid, fn s ->
        %{s | stream_ref: ref, context_warning_sent: true, status: :thinking}
      end)

      send(pid, {:stream_done, id, ref})
      assert_receive %Loopyard.Events.ChatAgent.StatusChanged{id: ^id, status: :idle}, 500

      state = :sys.get_state(pid)
      assert state.context_warning_sent == false
    end

    test "utilization under threshold → no warning appended", %{id: id} do
      pid = agent_pid(id)
      ref = make_ref()
      :sys.replace_state(pid, fn s -> %{s | stream_ref: ref} end)

      send(
        pid,
        {:stream_event, id, ref,
         %Event.SessionResult{
           model: "claude-sonnet-4-6",
           input_tokens: 100_000,
           output_tokens: 100,
           cache_read_tokens: 0,
           cost_usd: 0.05,
           duration_ms: 1_000,
           num_turns: 1
         }}
      )

      _ = :sys.get_state(pid)
      state = :sys.get_state(pid)

      refute Enum.any?(state.messages, fn m ->
               m.role == :system and String.contains?(m.content || "", "Context window")
             end)

      assert state.context_warning_sent == false
    end
  end
end
