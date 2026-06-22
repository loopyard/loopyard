defmodule LoopyardWeb.Live.WorkspaceLive.Components.ChatActivityTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias LoopyardWeb.Live.WorkspaceLive.Components.Chat

  defp tool(name, input), do: %{role: :tool, tool: name, input: input}

  describe "current_turn_activity/1" do
    test "lists only tools since the last human message, oldest→newest" do
      msgs = [
        %{role: :user, content: "older turn"},
        tool("Read", %{"file_path" => "/old.ex"}),
        %{role: :assistant, content: "done"},
        %{role: :user, content: "this turn"},
        tool("Read", %{"file_path" => "/a.ex"}),
        tool("Bash", %{"command" => "mix test"})
      ]

      assert [%{summary: "Read /a.ex"}, %{summary: "$ mix test"}] = Chat.current_turn_activity(msgs)
    end

    test "marks the latest action active and the rest done" do
      msgs = [
        %{role: :user, content: "go"},
        tool("Read", %{"file_path" => "/a.ex"}),
        tool("Bash", %{"command" => "ls"})
      ]

      assert [%{active: false}, %{active: true}] = Chat.current_turn_activity(msgs)
    end

    test "skips tool_result rows — only the calls themselves" do
      msgs = [
        %{role: :user, content: "go"},
        tool("Bash", %{"command" => "ls"}),
        %{role: :tool_result, content: "a.ex b.ex"}
      ]

      assert [%{summary: "$ ls", active: true}] = Chat.current_turn_activity(msgs)
    end

    test "is empty when no tools have run yet this turn" do
      assert Chat.current_turn_activity([%{role: :user, content: "go"}]) == []
    end
  end

  describe "thinking_indicator/1 renders the live feed" do
    test "shows each current-turn action with a status glyph" do
      msgs = [
        %{role: :user, content: "go"},
        tool("Read", %{"file_path" => "/a.ex"}),
        tool("mcp__loopyard-container__app_url", %{})
      ]

      html = render_component(&Chat.thinking_indicator/1, %{messages: msgs, word: "Working"})

      assert html =~ "Read /a.ex"
      # improved summary, not the old bare "App URL"
      assert html =~ "Get preview URL"
      refute html =~ ">App URL<"
      # done check + active marker both present
      assert html =~ "✓"
      assert html =~ "▸"
    end

    test "shows a live elapsed timer counting from the turn's start" do
      ts = ~U[2026-06-18 10:00:00Z]
      msgs = [%{role: :user, content: "go", timestamp: ts}, tool("Bash", %{"command" => "ls"})]

      # The elapsed timer now lives in the docked Reasoning Bar (above the input),
      # not the transcript feed — so it never scrolls off on a long turn.
      html =
        render_component(&Chat.reasoning_bar/1, %{messages: msgs, word: "Working", agent_id: "a1"})

      assert html =~ ~s(phx-hook="Elapsed")
      assert html =~ ~s(data-since="#{DateTime.to_unix(ts, :millisecond)}")
    end

    test "omits the timer when the turn start has no timestamp" do
      html =
        render_component(&Chat.thinking_indicator/1, %{
          messages: [%{role: :user, content: "go"}],
          word: "Working"
        })

      refute html =~ ~s(phx-hook="Elapsed")
    end

    test "explains an in-flight retry when the last response was a 529 overload" do
      msgs = [
        %{role: :assistant, content: "API Error: 529 Overloaded. This is a server-side issue."},
        %{role: :user, content: "try again"}
      ]

      html = render_component(&Chat.thinking_indicator/1, %{messages: msgs, word: "Working"})
      assert html =~ "overloaded"
      assert html =~ "Stop and resend"
    end

    test "flags a generic upstream 5xx as a retry too" do
      msgs = [
        %{role: :assistant, content: "API Error: 503 Service Unavailable"},
        %{role: :user, content: "go"}
      ]

      html = render_component(&Chat.thinking_indicator/1, %{messages: msgs, word: "Working"})
      assert html =~ "temporary server error"
    end

    test "no retry hint on a normal turn" do
      msgs = [%{role: :user, content: "go"}, tool("Bash", %{"command" => "ls"})]
      html = render_component(&Chat.thinking_indicator/1, %{messages: msgs, word: "Working"})
      refute html =~ "⚠"
    end
  end
end
