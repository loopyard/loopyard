defmodule Loopyard.Harness.Claude.Plan do
  @moduledoc """
  Maps Claude Code's native todo tools (`TaskCreate` / `TaskUpdate`) onto a
  `Loopyard.Plan`.

  This is the ONLY place that knows Claude's tool names and payload shapes. The
  plan itself is harness-neutral — a Codex or ACP adapter would be the same
  shape (turn the harness's native signal into `Loopyard.Plan` events) and feed
  the very same primitive. Harnesses with no todo mechanism just never produce
  events, and the plan stays empty.

  Claude assigns tasks sequential numbers ("Task #1", "#2", …) and `TaskUpdate`
  references them by that number via `taskId`. Because `Loopyard.Plan.add/3`
  also numbers tasks 1, 2, 3 … in creation order, the ids line up directly.
  """

  alias Loopyard.Plan

  @doc """
  The neutral `Loopyard.Plan` event for a Claude tool message, or `:ignore` for
  anything that isn't a task tool.
  """
  @spec event(map()) :: Plan.event() | :ignore
  def event(%{role: :tool, tool: "TaskCreate"} = msg) do
    input = msg[:input] || %{}
    subject = input["subject"] || input["activeForm"] || "Task"
    {:add, subject, active_form: input["activeForm"]}
  end

  def event(%{role: :tool, tool: "TaskUpdate"} = msg) do
    input = msg[:input] || %{}

    case Integer.parse(to_string(input["taskId"] || input["task_id"] || "")) do
      {id, _rest} -> {:set_status, id, Plan.parse_status(input["status"])}
      :error -> :ignore
    end
  end

  def event(_msg), do: :ignore

  @doc "Fold a single Claude tool message onto the plan."
  @spec apply_message(Plan.t(), map()) :: Plan.t()
  def apply_message(plan, msg), do: Plan.apply_event(plan, event(msg))

  @doc "Rebuild a plan from scratch over a message history (e.g. on boot/resume)."
  @spec from_messages(Plan.t(), [map()]) :: Plan.t()
  def from_messages(plan \\ [], messages) when is_list(messages),
    do: Enum.reduce(messages, plan, &apply_message(&2, &1))
end
