defmodule Loopyard.Events.WorkspaceSetup.PhaseStarted do
  @moduledoc "A setup phase began. `phase` is one of :worktree, :volume, :seeding, :registering."
  defstruct [:workspace_id, :phase, :started_at]
  @type t :: %__MODULE__{}
end
