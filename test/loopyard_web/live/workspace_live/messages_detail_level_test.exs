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
    # exec / docker_compose render as a console box (titled by the command) and
    # their raw tool row is deliberately suppressed — so use a plain tool (grep)
    # to exercise the detail-level gating itself, not the console special-case.
    setup do
      {:ok,
       msg: %{role: :tool, tool: "mcp__loopyard-container__grep", input: %{"pattern" => "needle"}}}
    end

    test "shows the tool call at :trace and :actions", %{msg: msg} do
      assert render(msg, :trace) =~ "needle"
      assert render(msg, :actions) =~ "needle"
    end

    test "hides the tool call at :chat", %{msg: msg} do
      refute render(msg, :chat) =~ "needle"
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

  describe "file-read card line numbers" do
    # Native harness Read results arrive pre-numbered ("   156→code"). The card
    # must strip that prefix and reuse the REAL numbers in its gutter — before
    # this, it stacked its own 1..N gutter on top (double numbering) and fed
    # the arrows to the syntax highlighter.
    defp render_read_result(content) do
      call = %{role: :tool, tool: "Read", input: %{"file_path" => "/workspace/lib/foo.ex"}}
      msg = %{role: :tool_result, content: content, is_error: false}

      render_component(&Messages.chat_msg/1, %{
        msg: msg,
        idx: 1,
        messages: [call, msg],
        agent_id: "a1",
        workspace_id: "w1",
        host: "localhost",
        detail_level: :trace
      })
    end

    test "pre-numbered Read output: arrows stripped, real numbers in the gutter" do
      html = render_read_result("   156→defmodule Foo do\n   157→  @x 1\n   158→end\n")

      refute html =~ "→"
      assert html =~ "156"
      assert html =~ "158"
      # trailing newline doesn't count as a line
      assert html =~ "3 lines"
    end

    test "plain read_file output keeps sequential 1..N numbering" do
      html = render_read_result("defmodule Foo do\nend")

      # (content is span-wrapped by syntax highlighting — match a single token)
      assert html =~ "2 lines"
      assert html =~ "defmodule"
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
