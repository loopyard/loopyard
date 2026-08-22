defmodule Loopyard.Events.Workstation.CredentialsChanged do
  @moduledoc """
  A workstation's stored credentials moved — an env var or an integration file
  was written or removed. Carries only WHICH key moved, never the value: this
  crosses PubSub to every connected viewer.
  """
  defstruct [:workstation_id, :source, :key]

  @type t :: %__MODULE__{
          workstation_id: String.t(),
          source: :env | :file,
          key: String.t()
        }
end
