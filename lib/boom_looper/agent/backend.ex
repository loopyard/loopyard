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
end
