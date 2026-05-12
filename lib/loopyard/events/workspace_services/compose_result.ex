defmodule Loopyard.Events.WorkspaceServices.ComposeResult do
  @moduledoc "A compose up/down attempt completed; `result` is `:ok` or `{:error, reason}`. LVs in :starting/:stopping watch for this so they transition out even when no per-service status changes."
  defstruct [:workspace_id, :result]
end
