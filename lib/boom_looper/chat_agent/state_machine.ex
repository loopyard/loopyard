defmodule BoomLooper.ChatAgent.StateMachine do
  @moduledoc """
  Explicit state graph for a ChatAgent session.

  An agent moves through these states over its lifetime:

      :booting       → the CLI subprocess is starting; no session yet
      :idle          → session up, waiting for input
      :thinking      → a turn is in flight
      :backoff       → a streaming task crashed; waiting on the
                       exponential-backoff window before retrying
      :rate_limited  → Claude API returned rate_limit_event :rejected;
                       scheduled auto-retry at resets_at_ms
      :auth_expired  → Claude CLI reported an auth error; terminal
                       without user re-auth
      :stopped       → explicitly stopped by user, session gone
      :crashed       → session died unexpectedly
      :destroying    → being removed; terminal state, no transitions out

  The transitions were previously implicit — set via `%{state | status: ...}`
  from 20+ sites across `ChatAgent`. Illegal moves (e.g. `:destroying →
  :idle`) would silently succeed. This module owns the graph in one
  place so the rules are visible and drift is catchable.

  ## How to use

      iex> StateMachine.allowed_transition?(:idle, :thinking)
      true

      iex> StateMachine.allowed_transition?(:destroying, :idle)
      false

      iex> StateMachine.transition(:idle, :thinking)
      {:ok, :thinking}

      iex> StateMachine.transition(:destroying, :idle)
      {:error, {:invalid_transition, :destroying, :idle}}

  Call sites in `ChatAgent` can migrate opportunistically: pass the
  current status and target to `transition/2`; on `{:error, _}` log
  an EventLog warning and either block the move or proceed with the
  original pattern. New code should go through `transition/2` by
  default.
  """

  # All possible states. Adding one without updating @transitions will
  # make the enumeration test fail — forcing the author to place the
  # new state in the graph.
  @states [
    :booting,
    :idle,
    :thinking,
    :backoff,
    :rate_limited,
    :auth_expired,
    :stopped,
    :crashed,
    :destroying
  ]

  # Directed graph of allowed transitions. Same-state "transitions"
  # (e.g. :idle → :idle) are excluded — they're no-ops, not state
  # changes, and should never be logged as such.
  @transitions %{
    # Boot can complete, crash, or be stopped mid-boot.
    booting: [:idle, :crashed, :stopped, :destroying],

    # An idle agent accepts work, can be stopped, can crash, can be destroyed.
    # Also: a SessionResult arriving on a fresh (empty) stream can
    # immediately surface a :rate_limit_event :rejected or
    # :auth_expired from the SDK, so :idle can pivot to those
    # degraded states without going through :thinking first.
    idle: [:thinking, :rate_limited, :auth_expired, :stopped, :crashed, :destroying],

    # A thinking agent finishes the turn (→ :idle), times out / errors
    # (→ :crashed), enters :backoff on a mid-stream task crash, or
    # gets stopped mid-turn. Audit-2 LOW #7. Also pivots to
    # :rate_limited / :auth_expired when the CLI emits those events
    # mid-turn.
    thinking: [:idle, :backoff, :rate_limited, :auth_expired, :stopped, :crashed, :destroying],

    # A backing-off agent is waiting for a scheduled :retry_session.
    # Retry success → :idle; give-up (or retry exhaustion) → :crashed.
    # Operator stop / destroy are still legal to bail out of the
    # backoff window. Audit-2 LOW #7.
    backoff: [:idle, :crashed, :stopped, :destroying],

    # Rate-limited agents auto-retry at resets_at_ms (→ :idle). User
    # can still stop / destroy to bail out of the wait, or the CLI
    # can transition to :auth_expired if the rate limit was coupled
    # with an auth issue.
    rate_limited: [:idle, :auth_expired, :stopped, :crashed, :destroying],

    # Auth-expired is essentially terminal without external
    # re-authentication. User can stop / destroy. A :crashed
    # transition is legal because the underlying CLI process may die.
    auth_expired: [:idle, :stopped, :crashed, :destroying],

    # Stopped agents can be restarted (→ :idle) or removed.
    stopped: [:idle, :destroying],

    # Crashed agents can be restarted, explicitly stopped, or removed.
    crashed: [:idle, :stopped, :destroying],

    # :destroying is terminal. Once you start removing, nothing comes back.
    destroying: []
  }

  @doc "Every possible status."
  def states, do: @states

  @doc "Map of `from → [allowed_to]`. Handy for introspection and tests."
  def transitions, do: @transitions

  @doc """
  Check whether `from → to` is a legal transition.

  Same-state "transitions" return `true` (they're no-ops — the caller
  isn't actually changing state, so there's nothing to validate).
  """
  def allowed_transition?(same, same) when is_atom(same), do: true

  def allowed_transition?(from, to) when is_atom(from) and is_atom(to) do
    case Map.fetch(@transitions, from) do
      {:ok, allowed} -> to in allowed
      :error -> false
    end
  end

  @doc """
  Validate and return the new status.

  Returns `{:ok, new}` on success, `{:error, {:invalid_transition, from, to}}`
  on an illegal move. Callers decide whether to refuse the move, log,
  or fail loud — this module just reports the verdict.
  """
  def transition(from, to) do
    if allowed_transition?(from, to) do
      {:ok, to}
    else
      {:error, {:invalid_transition, from, to}}
    end
  end
end
