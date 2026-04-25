defmodule BoomLooper.Events.WorkspaceSetup.Completed do
  @moduledoc "Workspace setup finished — `phase: :ready`."
  defstruct [:workspace_id, :total_duration_ms, :finished_at]
end
