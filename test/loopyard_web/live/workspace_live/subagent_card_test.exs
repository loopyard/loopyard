defmodule LoopyardWeb.Live.WorkspaceLive.SubagentCardTest do
  @moduledoc """
  A harness-native sub-agent's work nests under its delegating call: the
  transcript hides the sub-agent's own calls as rows and hands them to the
  parent's card as `children`; the card counts up while the sub-agent works
  and renders its report as prose when it lands.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias LoopyardWeb.Live.WorkspaceLive.Components.ChatStatus
  alias LoopyardWeb.Live.WorkspaceLive.Messages

  @ts ~U[2026-10-21 20:15:00Z]

  defp user(text), do: %{id: "u1", role: :user, content: text, timestamp: @ts}

  defp agent_call(id \\ "t_agent") do
    %{
      id: "m-#{id}",
      role: :tool,
      tool: "Agent",
      tool_kind: :agent,
      tool_id: id,
      input: %{"description" => "Find callers of greet", "subagent_type" => "Explore"},
      timestamp: @ts
    }
  end

  defp child(id, cmd, parent \\ "t_agent") do
    %{
      id: "m-#{id}",
      role: :tool,
      tool: "Bash",
      tool_kind: :command,
      tool_id: id,
      parent_tool_id: parent,
      input: %{"command" => cmd},
      timestamp: @ts
    }
  end

  defp result(id, content, opts \\ []) do
    %{
      id: "r-#{id}",
      role: :tool_result,
      tool_id: id,
      content: content,
      is_error: Keyword.get(opts, :is_error, false),
      timestamp: @ts
    }
  end

  defp render(messages, idx, ctx) do
    render_component(&Messages.chat_msg/1, %{
      msg: Enum.at(messages, idx),
      idx: idx,
      ctx: ctx,
      agent_id: "a1",
      workspace_id: "w1",
      host: "localhost",
      detail_level: :trace
    })
  end

  describe "Transcript.item_contexts/2 lineage" do
    test "children land on the parent; the children and their results are nested" do
      msgs = [
        user("go"),
        agent_call(),
        child("c1", "pwd"),
        result("c1", "/workspace"),
        child("c2", "grep -rn greet"),
        result("t_agent", "## Report\n\nfound 2")
      ]

      ctx = Messages.item_contexts(msgs, MapSet.new())

      assert [
               %{call: %{tool_id: "c1"}, result: %{content: "/workspace"}},
               %{call: %{tool_id: "c2"}, result: nil}
             ] =
               ctx[1].children

      assert ctx[1].settled
      refute ctx[1].nested
      assert ctx[2].nested
      assert ctx[3].nested
      assert ctx[4].nested
      # The parent's own report is a normal (visible) row.
      refute ctx[5].nested
    end

    test "an unsettled delegation is not settled, and a top-level call has no children" do
      msgs = [user("go"), agent_call(), child("c1", "pwd")]
      ctx = Messages.item_contexts(msgs, MapSet.new())
      refute ctx[1].settled
      assert [_] = ctx[1].children

      top = [
        user("go"),
        %{child("c9", "ls") | parent_tool_id: nil} |> Map.delete(:parent_tool_id)
      ]

      ctx = Messages.item_contexts(top, MapSet.new())
      assert ctx[1].children == nil
      refute ctx[1].nested
    end
  end

  describe "Transcript.visible_sections/3" do
    test "nested rows never render as rows; the delegation shows mid-turn" do
      msgs = [
        user("go"),
        agent_call(),
        child("c1", "pwd"),
        result("c1", "/workspace"),
        result("t_agent", "## Report")
      ]

      # Live turn (everything after the prompt is in flight).
      live = Messages.visible_sections(msgs, MapSet.new(), 0)
      ids = for %{body: body} <- live, {:run, items} <- body, {m, _, _} <- items, do: m.id
      assert ids == ["m-t_agent", "r-t_agent"]

      # Scrollback: same answer — the children are the card's, not the flow's.
      done = Messages.visible_sections(msgs, MapSet.new(), nil)
      ids = for %{body: body} <- done, {:run, items} <- body, {m, _, _} <- items, do: m.id
      assert ids == ["m-t_agent", "r-t_agent"]
    end
  end

  describe "the live feed" do
    test "neither the delegation nor its children show as feed chips" do
      msgs = [
        user("go"),
        agent_call(),
        child("c1", "pwd"),
        %{(child("top", "ls") |> Map.delete(:parent_tool_id)) | tool_id: "top"}
      ]

      assert [%{summary: "$ ls", active: true}] = ChatStatus.current_turn_activity(msgs)
    end
  end

  describe "the card" do
    test "working: names the job, the type, the latest call, and ticks" do
      msgs = [
        user("go"),
        agent_call(),
        child("c1", "pwd"),
        result("c1", "/workspace"),
        child("c2", "grep -rn greet")
      ]

      ctx = Messages.item_contexts(msgs, MapSet.new())
      html = render(msgs, 1, ctx[1])

      assert html =~ "Sub-agent: Find callers of greet"
      assert html =~ "Explore"
      assert html =~ "2 calls so far"
      assert html =~ "$ grep -rn greet"
      assert html =~ ~s(phx-hook="Elapsed")
      # Children are collapsed by default.
      refute html =~ "<details open"
      refute html =~ ~s(<details class="mt-1 group/nest" open)
    end

    test "names the model the sub-agent ran on when the harness reported it" do
      call = Map.put(agent_call(), :subagent_model, "claude-haiku-4-5-20251001")
      msgs = [user("go"), call, result("t_agent", "## Report")]
      ctx = Messages.item_contexts(msgs, MapSet.new())
      html = render(msgs, 1, ctx[1])

      assert html =~ "on Haiku 4.5"

      # A context-lane tag on the id is not part of the model's name.
      call = Map.put(agent_call(), :subagent_model, "claude-opus-5[1m]")
      msgs = [user("go"), call]
      assert render(msgs, 1, Messages.item_contexts(msgs, MapSet.new())[1]) =~ ~r/on Opus 5\s*</
    end

    test "names no model when none was reported" do
      msgs = [user("go"), agent_call(), result("t_agent", "## Report")]
      ctx = Messages.item_contexts(msgs, MapSet.new())
      refute render(msgs, 1, ctx[1]) =~ ~r/>\s*on /
    end

    test "settled: the counter is gone and the count is final" do
      msgs = [
        user("go"),
        agent_call(),
        child("c1", "pwd"),
        result("c1", "/workspace"),
        result("t_agent", "## Report\n\nok")
      ]

      ctx = Messages.item_contexts(msgs, MapSet.new())
      html = render(msgs, 1, ctx[1])

      assert html =~ "1 call"
      refute html =~ "so far"
      refute html =~ ~s(phx-hook="Elapsed")
    end

    test "the report renders as prose, not console output" do
      msgs = [user("go"), agent_call(), result("t_agent", "## Report\n\n- lib/app.rb:2")]
      ctx = Messages.item_contexts(msgs, MapSet.new())
      html = render(msgs, 2, ctx[2])

      assert html =~ "sub-agent report"
      assert html =~ "<h2"
      assert html =~ "lib/app.rb:2"
      refute html =~ "<pre"
    end

    test "a background sub-agent's closing line is one quiet row" do
      msgs = [
        user("go"),
        agent_call(),
        result(
          "t_agent",
          "Finished in the background — the agent folded its report into the reply."
        )
      ]

      ctx = Messages.item_contexts(msgs, MapSet.new())
      html = render(msgs, 2, ctx[2])

      assert html =~ "Finished in the background"
      refute html =~ "sub-agent report"
    end

    test "a failed sub-agent reads as an error" do
      msgs = [
        user("go"),
        agent_call(),
        result(
          "t_agent",
          "Interrupted — the turn ended before the background sub-agent reported.",
          is_error: true
        )
      ]

      ctx = Messages.item_contexts(msgs, MapSet.new())
      html = render(msgs, 2, ctx[2])
      assert html =~ "text-red-600"
    end

    test "a child row never renders on its own" do
      msgs = [user("go"), agent_call(), child("c1", "pwd")]
      ctx = Messages.item_contexts(msgs, MapSet.new())
      # The dispatcher still renders SOMETHING for a :tool row if asked — but
      # the section builder never asks (see visible_sections). This guards the
      # contract that drives the hiding, not the renderer.
      assert ctx[2].nested
    end
  end
end
