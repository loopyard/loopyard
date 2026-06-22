defmodule LoopyardWeb.Live.WorkspaceLive.MessagesPlanTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias LoopyardWeb.Live.WorkspaceLive.Messages

  # --- plan_tasks/1: the pure fold ------------------------------------------

  defp create(subject, active \\ nil),
    do: %{role: :tool, tool: "TaskCreate", input: %{"subject" => subject, "activeForm" => active}}

  defp update(task_id, status),
    do: %{role: :tool, tool: "TaskUpdate", input: %{"taskId" => task_id, "status" => status}}

  describe "plan_tasks/1" do
    test "numbers tasks in creation order and applies updates by taskId" do
      msgs = [
        create("Wire up click-to-focus"),
        create("Re-stack on pin"),
        create("Up/down nav"),
        update("1", "completed"),
        update("2", "in_progress")
      ]

      assert [
               %{n: 1, subject: "Wire up click-to-focus", status: "completed"},
               %{n: 2, subject: "Re-stack on pin", status: "in_progress"},
               %{n: 3, subject: "Up/down nav", status: "pending"}
             ] = Messages.plan_tasks(msgs)
    end

    test "ignores non-task messages and a final update wins" do
      msgs = [
        create("A"),
        %{role: :tool, tool: "mcp__loopyard-container__exec", input: %{"command" => "ls"}},
        update("1", "in_progress"),
        update("1", "completed")
      ]

      assert [%{n: 1, status: "completed"}] = Messages.plan_tasks(msgs)
    end

    test "is empty when there are no task calls" do
      assert Messages.plan_tasks([%{role: :user, content: "hi"}]) == []
    end
  end

  # --- transcript rendering --------------------------------------------------

  defp render_at(messages, idx) do
    render_component(&Messages.chat_msg/1, %{
      msg: Enum.at(messages, idx),
      idx: idx,
      messages: messages,
      agent_id: "a1",
      detail_level: :trace
    })
  end

  describe "plan card in the transcript" do
    test "renders ONE checklist at the first task call, folding later updates" do
      msgs = [
        create("Wire up click-to-focus"),
        create("Re-stack on pin"),
        update("1", "completed")
      ]

      html = render_at(msgs, 0)

      assert html =~ "Plan"
      assert html =~ "Wire up click-to-focus"
      assert html =~ "Re-stack on pin"
      # completed item is struck through; the count reflects 1 of 2 done
      assert html =~ "line-through"
      assert html =~ "1/2"
    end

    test "later task calls render nothing (folded into the first card)" do
      msgs = [create("A"), create("B"), update("1", "completed")]

      # the 2nd create and the update contribute no card of their own
      assert render_at(msgs, 1) =~ ~r/\A\s*<div>\s*<\/div>\s*\z/
      assert render_at(msgs, 2) =~ ~r/\A\s*<div>\s*<\/div>\s*\z/
    end

    test "ToolSearch rows are hidden entirely" do
      msgs = [%{role: :tool, tool: "ToolSearch", input: %{"query" => "select:exec"}}]
      assert render_at(msgs, 0) =~ ~r/\A\s*<div>\s*<\/div>\s*\z/
    end
  end

  # --- streamed-command de-duplication --------------------------------------

  describe "exec command shown once" do
    test "a streamed exec row is suppressed (the build card below owns it)" do
      msgs = [
        %{role: :tool, tool: "mcp__loopyard-container__exec", input: %{"command" => "ls -la"}},
        %{role: :build_done, content: "total 0", title: "ls -la"}
      ]

      # exec row at idx 0 is followed by a build card → no `$ ls -la` echo
      assert render_at(msgs, 0) =~ ~r/\A\s*<div>\s*<\/div>\s*\z/
    end

    test "a one-off exec with no streamed output still shows its $ command row" do
      msgs = [
        %{role: :tool, tool: "mcp__loopyard-container__exec", input: %{"command" => "true"}},
        %{role: :tool_result, content: "completed with no output"}
      ]

      assert render_at(msgs, 0) =~ "$ true"
    end
  end
end
