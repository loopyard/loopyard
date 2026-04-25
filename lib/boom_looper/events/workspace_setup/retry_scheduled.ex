defmodule BoomLooper.Events.WorkspaceSetup.RetryScheduled do
  @moduledoc """
  A transient failure happened; another attempt will run after `delay_ms`.
  Distinct from `Failed` — `Failed` only fires when retries are exhausted.
  """
  defstruct [:workspace_id, :phase, :attempt, :delay_ms, :scheduled_at]
end
