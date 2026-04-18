defmodule BoomLooper.Source.Local.SyncMonitor.StateMachine do
  @moduledoc """
  State graph for a Mutagen-backed file sync session.

  Five states:

      :starting — session launching (mutagen create + initial scan)
      :running  — sync healthy and actively reflecting changes
      :paused   — user or system has held the session (loopback-only,
                  container transition, etc.)
      :errored  — probe failed; backoff timer runs, retry pending
      :stopped  — no session (pre-boot, explicit stop, or after a
                  removed workspace)

  Transitions:

      :starting → :running | :errored | :paused | :stopped
      :running  → :paused | :errored | :stopped
      :paused   → :running | :starting | :errored | :stopped
      :errored  → :running | :starting | :paused | :stopped
      :stopped  → :starting

  Same-state is a legal no-op — the `transition/4` function in
  `SyncMonitor` calls this on every probe, and a successful probe
  against an already-`:running` session should not raise.

  Why this matters: probe results arrive asynchronously. A late
  `:running` probe can land after the user has already stopped the
  session, attempting an invalid `:stopped → :running` move. Before
  this module, the transition was applied silently and the UI
  lied about a session that had been explicitly torn down. Gating
  moves here makes the bug visible (logged warning) and keeps the
  stored state honest.
  """

  @states [:starting, :running, :paused, :errored, :stopped]

  @transitions %{
    starting: [:running, :errored, :paused, :stopped],
    running: [:paused, :errored, :stopped],
    paused: [:running, :starting, :errored, :stopped],
    errored: [:running, :starting, :paused, :stopped],
    stopped: [:starting]
  }

  @doc "Every possible state."
  def states, do: @states

  @doc "Map of `from → [allowed_to]`."
  def transitions, do: @transitions

  @doc """
  Check whether `from → to` is a legal transition.

  Same-state moves return `true` — they're idempotent no-ops, not
  state changes, so nothing to validate.
  """
  def allowed_transition?(same, same) when is_atom(same), do: true

  def allowed_transition?(from, to) when is_atom(from) and is_atom(to) do
    case Map.fetch(@transitions, from) do
      {:ok, allowed} -> to in allowed
      :error -> false
    end
  end

  @doc """
  Validate `from → to`. Returns `{:ok, to}` or
  `{:error, {:invalid_transition, from, to}}`.
  """
  def transition(from, to) do
    if allowed_transition?(from, to) do
      {:ok, to}
    else
      {:error, {:invalid_transition, from, to}}
    end
  end
end
