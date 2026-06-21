defmodule LoopyardWeb.Live.WorkspaceLive.TranscriptLayoutTest do
  @moduledoc """
  The agent renders as a continuous transcript (document + icon gutter), NOT
  bubbles: prose flows on the surface, the "Claude" identity shows once per run,
  and a faint left spine ties the run together. Humans stay bubbles.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias LoopyardWeb.Live.WorkspaceLive.Messages

  defp render(messages, idx) do
    render_component(&Messages.chat_msg/1, %{
      msg: Enum.at(messages, idx),
      idx: idx,
      messages: messages,
      agent_id: "a1",
      workspace_id: "w1",
      host: "localhost",
      detail_level: :trace
    })
  end

  defp user(text), do: %{role: :user, content: text}
  defp assistant(text), do: %{role: :assistant, content: text, timestamp: ~U[2026-06-21 09:30:00Z]}

  test "agent prose is a document, not a bubble" do
    html = render([user("go"), assistant("On it.")], 1)

    # No chat-bubble chrome on the agent's prose.
    refute html =~ "rounded-2xl"
    refute html =~ "bg-zinc-100 dark:bg-zinc-800"
    # It flows with a faint left spine (the gutter).
    assert html =~ "border-l"
    assert html =~ "On it."
  end

  test "the Claude identity shows once — at the start of a run" do
    # First agent message after a human → run header present.
    assert render([user("go"), assistant("First.")], 1) =~ "Claude"

    # A following agent message in the same run → no repeated header.
    refute render([user("go"), assistant("First."), assistant("Still me.")], 2) =~ "Claude"
  end

  test "the human stays a right-aligned bubble" do
    html = render([user("make it pop")], 0)
    assert html =~ "items-end"
    assert html =~ "rounded-2xl"
    assert html =~ "bg-violet-600"
  end
end
