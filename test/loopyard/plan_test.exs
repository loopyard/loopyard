defmodule Loopyard.PlanTest do
  use ExUnit.Case, async: true

  alias Loopyard.Plan

  describe "building directly from Elixir" do
    test "add numbers tasks in creation order; set_status mutates by id" do
      plan =
        Plan.new()
        |> Plan.add("A")
        |> Plan.add("B", active_form: "Doing B")
        |> Plan.set_status(2, :in_progress)

      assert [
               %{id: 1, subject: "A", active_form: nil, status: :pending},
               %{id: 2, subject: "B", active_form: "Doing B", status: :in_progress}
             ] = plan
    end

    test "set_status with an unknown id or status is a no-op" do
      plan = Plan.new() |> Plan.add("A")
      assert Plan.set_status(plan, 99, :completed) == plan
      assert Plan.set_status(plan, 1, :bogus) == plan
    end

    test "clear empties; complete_all marks everything done" do
      plan = Plan.new() |> Plan.add("A") |> Plan.add("B")
      assert Plan.clear(plan) == []
      assert Enum.all?(Plan.complete_all(plan), &(&1.status == :completed))
    end

    test "ids keep climbing even after items are removed-by-clear semantics" do
      # add three, then continue adding — ids never reused
      plan = Plan.new() |> Plan.add("A") |> Plan.add("B") |> Plan.add("C")
      assert Plan.add(plan, "D") |> List.last() |> Map.fetch!(:id) == 4
    end
  end

  describe "events + counts" do
    test "apply_events folds neutral events" do
      plan =
        Plan.apply_events(Plan.new(), [
          {:add, "A", []},
          {:add, "B", active_form: "Bing"},
          {:set_status, 1, :completed}
        ])

      assert Plan.counts(plan) == %{done: 1, total: 2}
      assert Plan.active(plan) == nil
      refute Plan.all_done?(plan)
    end

    test "all_done? only when there's at least one task and all completed" do
      refute Plan.all_done?([])
      assert Plan.all_done?(Plan.new() |> Plan.add("A") |> Plan.set_status(1, :completed))
    end

    test ":clear and :complete_all as events" do
      plan = Plan.new() |> Plan.add("A")
      assert Plan.apply_event(plan, :clear) == []
      assert Plan.apply_event(plan, :complete_all) |> List.first() |> Map.fetch!(:status) == :completed
      assert Plan.apply_event(plan, {:unknown, :thing}) == plan
    end
  end

  describe "parse_status (harness spelling tolerance)" do
    test "maps the common spellings, defaulting unknown to pending" do
      assert Plan.parse_status("completed") == :completed
      assert Plan.parse_status("done") == :completed
      assert Plan.parse_status("in-progress") == :in_progress
      assert Plan.parse_status("active") == :in_progress
      assert Plan.parse_status("pending") == :pending
      assert Plan.parse_status("whatever") == :pending
      assert Plan.parse_status(:in_progress) == :in_progress
      assert Plan.parse_status(nil) == :pending
    end
  end
end
