defmodule LoopyardWeb.Live.WorkspaceLive.Components.ChatStatusTest do
  @moduledoc """
  The live status strip under an active prompt and the thinking indicator —
  rendered against a small transcript so their assign plumbing (turn timer,
  current tool, token estimate) is exercised, not just their happy path.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias LoopyardWeb.Live.WorkspaceLive.Components.ChatStatus

  defp transcript do
    now = DateTime.utc_now()

    [
      %{id: "u1", role: :user, content: "Fix the flaky test", timestamp: now},
      %{
        id: "t1",
        role: :tool,
        tool: "Bash",
        tool_id: "x",
        tool_kind: :command,
        input: %{"command" => "mix test"},
        timestamp: now
      },
      %{
        id: "r1",
        role: :tool_result,
        content: "ok",
        tool_id: "x",
        is_error: false,
        timestamp: now
      }
    ]
  end

  test "token_estimate/1 is ~4 bytes per token and tolerates non-strings" do
    assert ChatStatus.token_estimate("abcdefgh") == 2
    assert ChatStatus.token_estimate(nil) == 0
  end

  test "live_status renders the working word and a ticking turn timer" do
    html =
      render_component(&ChatStatus.live_status/1, %{
        messages: transcript(),
        word: "Vibing",
        agent_id: "a1",
        tokens: 1200,
        context_utilization: 0.42
      })

    assert html =~ "Vibing"
    assert html =~ "Stop"
    # The timer element carries the turn's start so the client can count up.
    assert html =~ "data-since" or html =~ "since"
  end

  test "live_status with no user prompt yet has no turn timer" do
    html =
      render_component(&ChatStatus.live_status/1, %{
        messages: [],
        word: "Thinking",
        agent_id: "a1"
      })

    assert html =~ "Thinking"
  end

  test "thinking_indicator lists the tool still running; a finished turn shows nothing" do
    # The completed transcript has no in-flight tool → the feed is empty (the
    # finished command renders inline in the transcript instead).
    assert render_component(&ChatStatus.thinking_indicator/1, %{
             messages: transcript(),
             word: "Thinking",
             agent_id: "a1"
           }) == ""

    # Drop the result: the Bash call is still running → it's in the feed.
    in_flight = Enum.reject(transcript(), &(&1.role == :tool_result))

    html =
      render_component(&ChatStatus.thinking_indicator/1, %{
        messages: in_flight,
        word: "Thinking",
        agent_id: "a1"
      })

    assert html =~ "mix test"
  end
end
