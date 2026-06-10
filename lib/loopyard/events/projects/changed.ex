defmodule Loopyard.Events.Projects.Changed do
  @moduledoc """
  The global project list changed — a project was created or removed. Carries
  just enough for a subscriber to decide to reload; the list itself is read from
  the registry (the broadcast is a nudge, not the payload).
  """
  @enforce_keys [:action]
  defstruct [:action, :project_id]

  @type t :: %__MODULE__{
          action: :created | :removed,
          project_id: String.t() | nil
        }
end
