defmodule BoomLooper.Events.WorkspaceSetup.PhaseCompleted do
  @moduledoc "A setup phase finished successfully. `duration_ms` is wall time spent in the phase."
  defstruct [:workspace_id, :phase, :duration_ms, :finished_at]
end
