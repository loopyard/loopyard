defmodule Loopyard.Events.WorkspaceSetup.Started do
  @moduledoc "Workspace setup saga has begun (or restarted via Retry)."
  defstruct [:workspace_id, :project_id, :attempt, :started_at]
  @type t :: %__MODULE__{}
end
