defmodule LoopyardWeb.Live.WorkspaceLive.ToolCountTest do
  @moduledoc """
  A long turn should say how much work it's doing — as a fact, not an alarm.

  This replaced a permanent chat message ("⚠ Agent has made 50 tool calls in
  this single turn … it may be stuck … click Stop") that fired on a pure COUNT.
  A codebase-wide refactor legitimately runs past 50 tool calls, so it accused
  healthy agents of being broken, in the transcript, forever.
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias LoopyardWeb.Live.WorkspaceLive.Components.ChatStatus

  defp row(tool_calls) do
    render_component(&ChatStatus.live_status/1, %{
      messages: [],
      word: "Thinking",
      agent_id: "a1",
      mode: :full,
      streaming_text: "",
      active_tool: nil,
      tool_calls: tool_calls,
      tokens: 0,
      context_utilization: 0.0
    })
  end

  test "a busy turn shows its tool count" do
    assert row(50) =~ "50 tools"
  end

  test "a short turn stays quiet" do
    refute row(3) =~ "tools"
  end

  test "the runaway ACCUSATION is gone from the transcript" do
    src = File.read!("lib/loopyard/chat_agent/stream_handler/loop_guard.ex")

    refute src =~ "tool calls in this single turn.",
           "a tool COUNT must not write a permanent chat message"

    assert src =~ "tool_runaway",
           "it stays observable as telemetry + EventLog"

    assert src =~ "times in a row with the same input",
           "the same-tool-same-input guard is EVIDENCE, not a count — it stays"
  end
end
