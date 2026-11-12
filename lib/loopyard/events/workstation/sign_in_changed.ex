defmodule Loopyard.Events.Workstation.SignInChanged do
  @moduledoc """
  A guided sign-in for one of a workstation's integrations moved to a new
  phase (see `Loopyard.Workstation.SignIn`). Carries the phase, the vendor's
  authorize URL while the flow waits for its code, and a human error on
  failure — NEVER the pasted code or the token: this crosses PubSub to every
  connected viewer.
  """
  defstruct [:workstation_id, :tool, :phase, :url, :error]

  @type phase :: :starting | :awaiting_code | :exchanging | :done | :failed | :idle

  @type t :: %__MODULE__{
          workstation_id: String.t(),
          tool: String.t(),
          phase: phase(),
          url: String.t() | nil,
          error: String.t() | nil
        }
end
