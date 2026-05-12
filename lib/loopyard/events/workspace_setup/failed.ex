defmodule Loopyard.Events.WorkspaceSetup.Failed do
  @moduledoc """
  Workspace setup failed terminally (after any auto-retries). `error` is the
  structured map from `Loopyard.Workspace.Setup.Error` with `code`, `why`,
  `consequence`, `action`, `transient?`, `raw`.
  """
  defstruct [:workspace_id, :phase, :error]
end
