defmodule Loopyard.Events.Workspaces.Changed do
  @moduledoc """
  A project's workspace list changed — a workspace was created or removed, or a
  workspace's status changed. A nudge to reload from the registry (the broadcast
  is the signal, not the payload).
  """
  @enforce_keys [:project_id, :action]
  defstruct [:project_id, :action, :workspace_id]

  @type t :: %__MODULE__{
          project_id: String.t(),
          action: :created | :removed | :status,
          workspace_id: String.t() | nil
        }
end
