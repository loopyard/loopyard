defmodule Loopyard.Events.Workstation.SignInChanged do
  @moduledoc """
  A guided sign-in for one of a workstation's integrations moved to a new
  phase (see `Loopyard.Workstation.SignIn`). Carries the phase, the vendor's
  authorize / verification URL while the flow waits on the human, and a human
  error on failure — NEVER the pasted code, the token or a credential file:
  this crosses PubSub to every connected viewer.

  `user_code` is a device flow's one-time code (`:awaiting_approval`). It is
  carried ON PURPOSE: the human must read it off this page to type it on the
  vendor's, it expires in minutes, works once, and is useless without the
  device secret that never leaves the sign-in container. `nil` otherwise.
  """
  defstruct [:workstation_id, :tool, :phase, :url, :error, :user_code]

  @type phase ::
          :starting | :awaiting_code | :exchanging | :awaiting_approval | :done | :failed | :idle

  @type t :: %__MODULE__{
          workstation_id: String.t(),
          tool: String.t(),
          phase: phase(),
          url: String.t() | nil,
          error: String.t() | nil,
          user_code: String.t() | nil
        }
end
