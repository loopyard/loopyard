defmodule Loopyard.Harness.Claude.PlanTest do
  use ExUnit.Case, async: true

  alias Loopyard.Harness.Claude.Plan, as: Adapter
  alias Loopyard.Plan

  defp create(subject, active \\ nil),
    do: %{role: :tool, tool: "TaskCreate", input: %{"subject" => subject, "activeForm" => active}}

  defp update(task_id, status),
    do: %{role: :tool, tool: "TaskUpdate", input: %{"taskId" => task_id, "status" => status}}

  describe "event/1" do
    test "TaskCreate → :add with subject + active_form" do
      assert {:add, "Wire it up", active_form: "Wiring"} =
               Adapter.event(create("Wire it up", "Wiring"))
    end

    test "TaskUpdate → :set_status by numeric taskId, with status parsed" do
      assert {:set_status, 2, :completed} = Adapter.event(update("2", "completed"))
      assert {:set_status, 1, :in_progress} = Adapter.event(update("1", "in_progress"))
    end

    test "non-task tools and bad taskIds are ignored" do
      assert Adapter.event(%{role: :tool, tool: "Bash", input: %{}}) == :ignore
      assert Adapter.event(update("not-a-number", "completed")) == :ignore
      assert Adapter.event(%{role: :assistant, content: "hi"}) == :ignore
    end
  end

  describe "from_messages/2" do
    test "folds a Claude task stream into a Loopyard.Plan, ids aligned to taskId" do
      msgs = [
        create("Layer focus navigation"),
        create("Re-stack controls"),
        create("HTTP hop"),
        update("1", "completed"),
        update("2", "completed")
      ]

      plan = Adapter.from_messages([], msgs)

      assert Plan.counts(plan) == %{done: 2, total: 3}

      assert [
               %{id: 1, status: :completed},
               %{id: 2, status: :completed},
               %{id: 3, subject: "HTTP hop", status: :pending}
             ] = plan
    end

    test "apply_message is the incremental form of from_messages" do
      msgs = [create("A"), create("B"), update("1", "completed")]
      incremental = Enum.reduce(msgs, Plan.new(), &Adapter.apply_message(&2, &1))
      assert incremental == Adapter.from_messages([], msgs)
    end
  end
end
