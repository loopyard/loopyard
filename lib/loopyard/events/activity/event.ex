defmodule Loopyard.Events.Activity.Event do
  @moduledoc """
  One unit of agent activity, tagged with WHERE it happened so subscribers can
  filter by proximity (this agent / workspace / project / elsewhere).

  Fields:
    * `agent_id`, `agent_name` — who
    * `workspace_id`, `project_id` — where
    * `kind` — `:status` | `:tool` | `:turn_end`
    * `summary` — a one-liner ("thinking", "idle", a tool name, or for
      `:turn_end` the turn's OUTCOME sentence — `ChatAgent.TurnSummary`,
      computed once where the messages are in hand)
    * `at` — DateTime the activity was recorded
  """
  defstruct [:agent_id, :agent_name, :workspace_id, :project_id, :kind, :summary, :at]
end
