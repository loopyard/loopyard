defmodule BoomLooper.Agent.Backend do
  @moduledoc """
  Behaviour for conversation backends.

  A backend manages a conversation session — starting it, streaming prompt
  responses as `BoomLooper.Agent.Event` structs, and tearing it down.

  The CLI becomes one implementation (`Backend.ClaudeCode`); a future direct-API
  backend can implement the same interface.
  """

  @type session :: term()

  @callback start_session(opts :: keyword()) :: {:ok, session} | {:error, term()}
  @callback stream(session, prompt :: String.t()) :: Enumerable.t()
  @callback stop(session) :: :ok
  @callback session_alive?(session) :: boolean()

  @doc """
  Return the backend-specific conversation id for this live session,
  or `nil` if none is available yet. For `Backend.ClaudeCode` this is
  the Claude CLI session_id, which can be passed back as `resume:` to
  restore context when the session process is replaced.
  """
  @callback session_id(session) :: String.t() | nil
end
