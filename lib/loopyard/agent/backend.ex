defmodule Loopyard.Agent.Backend do
  @moduledoc """
  Behaviour for conversation backends.

  A backend manages a conversation session — starting it, streaming prompt
  responses as `Loopyard.Agent.Event` structs, and tearing it down.

  The CLI becomes one implementation (`Backend.ClaudeCode`); a future direct-API
  backend can implement the same interface.
  """

  @type session :: term()

  @callback start_session(opts :: keyword()) :: {:ok, session} | {:error, term()}
  @callback stream(session, prompt :: String.t()) :: Enumerable.t()
  @callback stop(session) :: :ok
  @callback session_alive?(session) :: boolean()

  @doc """
  Interrupt the IN-FLIGHT turn while keeping the session ALIVE — the warm-cancel
  the turn machine's `:cancel_turn` effect maps to. The agent stops generating
  and the conversation can continue on the same session (no kill, no log-replay).
  Distinct from `stop/1`, which tears the session down. For `Backend.ClaudeCode`
  this is the CLI's interrupt control request; for ACP it's `session/cancel`.
  Best-effort: a backend that can't interrupt may fall back to `stop/1`.
  """
  @callback cancel_turn(session) :: :ok | {:error, term()}

  @doc """
  Return the backend-specific conversation id for this live session,
  or `nil` if none is available yet. For `Backend.ClaudeCode` this is
  the Claude CLI session_id, which can be passed back as `resume:` to
  restore context when the session process is replaced.
  """
  @callback session_id(session) :: String.t() | nil
end
