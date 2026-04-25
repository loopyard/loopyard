defmodule BoomLooper.Events.WorkspaceSetup.PhaseStarted do
  @moduledoc "A setup phase began. `phase` is one of :worktree, :volume, :seeding, :registering."
  defstruct [:workspace_id, :phase, :started_at]
end
