defmodule BoomLooper.Agent.Event.AuthStatus do
  @moduledoc """
  Authentication status from the Claude CLI. `error` being non-nil
  signals that the CLI can't authenticate — ChatAgent transitions to
  `:auth_expired` and stops retrying until a human intervenes (there
  is no automated recovery from bad creds).
  """
  defstruct [:is_authenticating, :error, output: []]
  @type t :: %__MODULE__{
          is_authenticating: boolean(),
          error: String.t() | nil,
          output: [String.t()]
        }
end
