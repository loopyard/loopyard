defmodule LoopyardWeb.Live.WorkspaceLive.BlockedStatusTest do
  @moduledoc """
  A turn parked inside `ask_user` is WAITING, not working.

  It used to render the thinking bar: a violet spinner, the tool count and a
  running clock ("Drafting a question… 2h 10m · 6 tools") for a turn that was
  doing nothing but waiting on a person — which read as busywork nobody could
  interpret. Blocked says so, and shows no ticking numbers.
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias LoopyardWeb.Live.WorkspaceLive.Components.Chat.Status
  alias LoopyardWeb.Live.WorkspaceLive.Components.ChatStatus

  defp agent(status), do: %{id: "a1", status: status}

  defp pending_question,
    do: %{
      id: "q1",
      role: :question,
      status: :pending,
      questions: [%{prompt: "Which one?", header: "", options: []}],
      timestamp: DateTime.utc_now()
    }

  defp answered_question, do: %{pending_question() | id: "q0", status: :answered}

  defp row(mode) do
    render_component(&ChatStatus.live_status/1, %{
      messages: [],
      word: "Drafting a question",
      agent_id: "a1",
      mode: mode,
      streaming_text: "",
      active_tool: "mcp__loopyard-container__ask_user",
      tool_calls: 6,
      tokens: 1000,
      context_utilization: 0.5
    })
  end

  test "a pending question makes the turn blocked" do
    assert Status.live_status_mode(agent(:thinking), [pending_question()], "") == :blocked
  end

  test "live output wins — text still streaming is working, whatever is pending" do
    assert Status.live_status_mode(agent(:thinking), [pending_question()], "half a sen") ==
             :thinking
  end

  test "an answered question is not blocked" do
    assert Status.live_status_mode(agent(:thinking), [answered_question()], "") == :thinking
  end

  test "harness maintenance still wins over blocked" do
    assert Status.live_status_mode(agent(:compacting), [pending_question()], "") == :compacting
    assert Status.live_status_mode(agent(:backoff), [pending_question()], "") == :restarting
  end

  test "the blocked row says what it's waiting for and counts nothing" do
    html = row(:blocked)
    assert html =~ "Waiting on your answer"
    refute html =~ "6 tools"
    refute html =~ "turn-elapsed"
    refute html =~ "% ctx"
    # Stop is still there: a blocked turn can be abandoned.
    assert html =~ "Stop"
  end

  test "the thinking row still counts its work" do
    html = row(:thinking)
    assert html =~ "6 tools"
    assert html =~ "Drafting a question"
  end
end
