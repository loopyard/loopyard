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

    test "a short error renders as an always-visible inline row (no disclosure)" do
      msg = %{role: :tool_result, content: "boom", is_error: true}
      html = render(msg, :actions)
      assert html =~ "boom"
      refute html =~ "<details"
    end

    test "a long error keeps the disclosure, forced open even at :actions" do
      msg = %{role: :tool_result, content: Enum.map_join(1..5, "\n", &"err #{&1}"), is_error: true}
      html = render(msg, :actions)
      assert html =~ "<details"
      assert html =~ "open"
    end
  end

  describe "tool_result ↔ tool call pairing" do
    # Tool calls can run in PARALLEL: every call is emitted first, then every
    # result. Position-based pairing attributed the first result to the LAST
    # call — an `ls` dump rendered as a ruby file card. Results pair by
    # tool_id; legacy messages (no tool_id) pair by order of arrival.
    defp render_at(messages, idx) do
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

    test "parallel calls: each result pairs with its own call by tool_id" do
      messages = [
        %{role: :tool, tool: "Bash", tool_id: "t1", input: %{"command" => "ls -l /workspace"}},
        %{role: :tool, tool: "Read", tool_id: "t2", input: %{"file_path" => "/workspace/a.rb"}},
        %{role: :tool_result, tool_id: "t1", content: "total 0\n-rw-r--r-- docs", is_error: false},
        %{role: :tool_result, tool_id: "t2", content: "File does not exist.", is_error: true}
      ]

      # Bash result → console box titled by the command, NOT a file card
      bash_html = render_at(messages, 2)
      assert bash_html =~ "ls -l /workspace"
      refute bash_html =~ "a.rb"

      # failed Read → inline error row, NOT a "ruby" file card
      read_html = render_at(messages, 3)
      assert read_html =~ "File does not exist."
      refute read_html =~ "ruby"
    end

    test "legacy messages without tool_id pair by order of arrival" do
      messages = [
        %{role: :tool, tool: "Bash", input: %{"command" => "echo hi"}},
        %{role: :tool, tool: "Read", input: %{"file_path" => "/workspace/lib/foo.ex"}},
        %{role: :tool_result, content: "hi", is_error: false},
        %{role: :tool_result, content: "   1→defmodule Foo do\n   2→end", is_error: false}
      ]

      # first result belongs to the first call (Bash) → console box
      assert render_at(messages, 2) =~ "echo hi"
      # second result belongs to Read → file card with the filename
      assert render_at(messages, 3) =~ "foo.ex"
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

    test "a stray non-numbered tail line doesn't break arrow stripping" do
      # Real Read results can carry harness chrome (truncation notes,
      # system-reminder tails). Detection is tolerant: ≥90% matching lines
      # still counts as the native format; the stray line is dropped.
      numbered = Enum.map_join(1..20, "\n", &"   #{&1}→line #{&1}")
      html = render_read_result(numbered <> "\n(truncated by the harness)")

      refute html =~ "→"
      assert html =~ "20 lines"
      refute html =~ "truncated by the harness"
    end

    test "syntax highlighting is active (makeup scope present)" do
      html = render_read_result("   1→defmodule Foo do\n   2→end")
      assert html =~ "highlight"
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
