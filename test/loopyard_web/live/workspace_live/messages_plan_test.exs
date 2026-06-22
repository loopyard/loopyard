defmodule LoopyardWeb.Live.WorkspaceLive.MessagesPlanTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias LoopyardWeb.Live.WorkspaceLive.Messages
  alias Loopyard.Plan

  # The fold/adapter logic now lives in Loopyard.Plan + Loopyard.Harness.Claude.Plan
  # (see their own tests). These tests cover the transcript rendering: the docked
  # plan card, and suppression of the raw task/search tool rows.

  defp task_msg(tool, input), do: %{role: :tool, tool: tool, input: input}

  defp render_at(messages, idx) do
    render_component(&Messages.chat_msg/1, %{
      msg: Enum.at(messages, idx),
      idx: idx,
      messages: messages,
      agent_id: "a1",
      detail_level: :trace
    })
  end

  describe "plan_card/1 (docked checklist)" do
    test "renders the Loopyard.Plan with subjects, count, struck-through done, Clear" do
      plan =
        Plan.new()
        |> Plan.add("Wire up click-to-focus")
        |> Plan.add("Re-stack on pin")
        |> Plan.set_status(1, :completed)

      html = render_component(&Messages.plan_card/1, %{tasks: plan, agent_id: "a1"})

      assert html =~ "Plan"
      assert html =~ "Wire up click-to-focus"
      assert html =~ "Re-stack on pin"
      assert html =~ "line-through"
      assert html =~ "1/2"
      # human can dismiss it without the model
      assert html =~ "clear_plan"
      assert html =~ "Clear"
    end

    test "renders nothing when the plan is empty" do
      assert render_component(&Messages.plan_card/1, %{tasks: [], agent_id: "a1"}) =~ ~r/\A\s*\z/
    end

    test "no Clear button without an agent_id" do
      plan = Plan.new() |> Plan.add("A")
      refute render_component(&Messages.plan_card/1, %{tasks: plan, agent_id: nil}) =~ "clear_plan"
    end
  end

  describe "task & search rows are suppressed inline (they live in the docked plan)" do
    test "TaskCreate / TaskUpdate rows render nothing in the transcript" do
      msgs = [
        task_msg("TaskCreate", %{"subject" => "A"}),
        task_msg("TaskUpdate", %{"taskId" => "1", "status" => "completed"})
      ]

      assert render_at(msgs, 0) =~ ~r/\A\s*<div>\s*<\/div>\s*\z/
      assert render_at(msgs, 1) =~ ~r/\A\s*<div>\s*<\/div>\s*\z/
    end

    test "ToolSearch rows are hidden entirely" do
      msgs = [task_msg("ToolSearch", %{"query" => "select:exec"})]
      assert render_at(msgs, 0) =~ ~r/\A\s*<div>\s*<\/div>\s*\z/
    end
  end

  describe "streamed exec command shown once" do
    test "a streamed exec row is suppressed (the build card below owns it)" do
      msgs = [
        %{role: :tool, tool: "mcp__loopyard-container__exec", input: %{"command" => "ls -la"}},
        %{role: :build_done, content: "total 0", title: "ls -la"}
      ]

      assert render_at(msgs, 0) =~ ~r/\A\s*<div>\s*<\/div>\s*\z/
    end

    test "a one-off exec with no streamed output keeps its $ command row" do
      msgs = [
        %{role: :tool, tool: "mcp__loopyard-container__exec", input: %{"command" => "true"}},
        %{role: :tool_result, content: "completed with no output"}
      ]

      assert render_at(msgs, 0) =~ "$ true"
    end
  end

  describe "recovery summary no longer masquerades as a user message" do
    test "a 'Your session crashed' :user message renders as a muted system note" do
      msg = %{role: :user, content: "Your session crashed and was restarted. Here's what..."}

      html =
        render_component(&Messages.chat_msg/1, %{
          msg: msg,
          idx: 0,
          messages: [msg],
          agent_id: "a1",
          detail_level: :trace
        })

      assert html =~ "Session restarted"
      refute html =~ "YOU"
      refute html =~ "violet-100"
    end
  end
end
