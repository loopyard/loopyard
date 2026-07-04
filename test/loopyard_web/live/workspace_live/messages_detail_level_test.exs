defmodule LoopyardWeb.Live.WorkspaceLive.MessagesDetailLevelTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias LoopyardWeb.Live.WorkspaceLive.Messages

  defp render(msg, level) do
    render_component(&Messages.chat_msg/1, %{
      msg: msg,
      idx: 0,
      messages: [msg],
      agent_id: "a1",
      workspace_id: "w1",
      host: "localhost",
      detail_level: level
    })
  end

  describe "tool call gating" do
    setup do
      {:ok,
       msg: %{role: :tool, tool: "mcp__loopyard-container__exec", input: %{"command" => "ls"}}}
    end

    test "shows the tool call at :trace and :actions", %{msg: msg} do
      assert render(msg, :trace) =~ "ls"
      assert render(msg, :actions) =~ "ls"
    end

    test "hides the tool call at :chat", %{msg: msg} do
      refute render(msg, :chat) =~ "ls"
    end
  end

  describe "tool result gating + disclosure" do
    setup do
      {:ok, msg: %{role: :tool_result, content: "line one\nline two", is_error: false}}
    end

    test "renders inside a <details>, OPEN at :trace", %{msg: msg} do
      html = render(msg, :trace)
      assert html =~ "<details"
      assert html =~ "open"
      assert html =~ "line one"
    end

    test "renders the <details> CLOSED at :actions (drill down)", %{msg: msg} do
      html = render(msg, :actions)
      assert html =~ "<details"
      # the content is still in the DOM (drillable) but the disclosure is closed
      refute html =~ ~s(<details class="pl-10 py-0.5 group/result" open)
    end

    test "hides output entirely at :chat", %{msg: msg} do
      html = render(msg, :chat)
      refute html =~ "line one"
      refute html =~ "<details"
    end

    test "error output is forced open even at :actions" do
      msg = %{role: :tool_result, content: "boom", is_error: true}
      assert render(msg, :actions) =~ "open"
    end
  end

  describe "reasoning (thinking) gating" do
    setup do
      {:ok, msg: %{role: :thinking, content: "Let me reason about this"}}
    end

    test "open at :trace, present-but-collapsed at :actions", %{msg: msg} do
      assert render(msg, :trace) =~ "Reasoning"
      assert render(msg, :trace) =~ "Let me reason about this"
      assert render(msg, :actions) =~ "Reasoning"
    end

    test "hidden at :chat", %{msg: msg} do
      refute render(msg, :chat) =~ "Reasoning"
    end
  end
end
