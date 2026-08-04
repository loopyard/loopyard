defmodule Loopyard.ChatAgent.StreamHandler.LoopGuard do
  @moduledoc """
  Tool-call loop + runaway detection for a streaming turn.

  Two independent guards, both warn-once and reset on `stream_done`:

    * loop: same tool + same input `@tool_loop_threshold` times in a row
      (tracked via `state.last_tool_call` — `{hash, consecutive_count}`);
    * runaway: `@turn_tool_limit` tool calls (any shape) in one turn
      (tracked via `state.tool_calls_this_turn` / `tool_runaway_warned`).

  Called from `StreamHandler.process_event/2` on every `%Event.ToolCall{}`.
  State in, state out — no side effects beyond the inline warning message
  (+ telemetry / EventLog).
  """

  alias Loopyard.ChatAgent.{MessageLog, Persistence}
  alias Loopyard.Events

  # Loop-detection threshold: same tool + same input N times in a row.
  @tool_loop_threshold 5

  # Runaway cap: total tool calls in a single turn.
  @turn_tool_limit 50

  # Detect same-tool+same-input loops.
  def maybe_detect_tool_loop(state, id, tool_name, tool_input) do
    hash = tool_call_hash(tool_name, tool_input)

    {new_count, warn?} =
      case state.last_tool_call do
        {^hash, count} when count + 1 == @tool_loop_threshold ->
          {count + 1, true}

        {^hash, count} ->
          {count + 1, false}

        _ ->
          {1, false}
      end

    state = %{state | last_tool_call: {hash, new_count}}

    if warn? do
      :telemetry.execute(
        [:loopyard, :agent, :tool_loop_detected],
        %{consecutive: new_count},
        %{agent_id: id, tool: tool_name}
      )

      Loopyard.EventLog.warning(
        "agent:#{state.name}",
        "Tool-call loop — `#{tool_name}` called #{new_count}× with same input"
      )

      warn_msg = %{
        role: :system,
        content:
          "⚠ Agent called `#{tool_name}` #{new_count} times in a row with the same input — " <>
            "it may be stuck in a retry loop. Consider stopping the agent and providing a " <>
            "different hint, or check whether the tool is returning a consistent error.",
        timestamp: DateTime.utc_now()
      }

      {state, warn_msg} = MessageLog.append(state, warn_msg)
      Persistence.persist_message(state, warn_msg)

      Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
        agent_id: id,
        msg: warn_msg
      })

      state
    else
      state
    end
  end

  # Detect tool-call runaway (too many tool calls in a single turn).
  def maybe_detect_tool_runaway(%{tool_runaway_warned: true} = state, _id), do: state

  def maybe_detect_tool_runaway(%{tool_calls_this_turn: n} = state, id)
      when n >= @turn_tool_limit do
    :telemetry.execute(
      [:loopyard, :agent, :tool_runaway],
      %{tool_calls_this_turn: n},
      %{agent_id: id}
    )

    Loopyard.EventLog.warning(
      "agent:#{state.name}",
      "Tool-call runaway — #{n} tool calls in a single turn"
    )

    # NO chat message. A COUNT is not evidence of a problem: a codebase-wide
    # refactor legitimately runs well past 50 tool calls, so this fired on
    # perfectly healthy turns and left a permanent "⚠ … either it's stuck or
    # it's looping … click Stop" in the transcript. It made working agents read
    # as broken ones — reported as "WTF is that? Why is everything fucked?"
    #
    # It also broke the house rule: a message is earned when the user must act
    # AND the system can't self-fix. Here there is nothing to fix; the agent is
    # working. The honest version of this signal is the live tool COUNT next to
    # the elapsed timer (chat_status), which says what's happening without
    # claiming something is wrong. Telemetry + EventLog keep it observable.
    #
    # The same-tool-same-input guard above is different and stays: five
    # identical calls in a row IS evidence, not a count.
    %{state | tool_runaway_warned: true}
  end

  def maybe_detect_tool_runaway(state, _id), do: state

  # Fingerprint a tool call for loop detection.
  defp tool_call_hash(tool_name, tool_input) do
    raw = :erlang.term_to_binary({tool_name, tool_input})
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end
end
