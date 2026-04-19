defmodule BoomLooper.ChatAgent.StateMachine do
  @moduledoc """
  Explicit state graph for a ChatAgent session.

  An agent moves through six states over its lifetime:

      :booting      → the CLI subprocess is starting; no session yet
      :idle         → session up, waiting for input
      :thinking     → a turn is in flight
      :stopped      → explicitly stopped by user, session gone
      :crashed      → session died unexpectedly
      :destroying   → being removed; terminal state, no transitions out

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
  @states [:booting, :idle, :thinking, :stopped, :crashed, :destroying]

  # Directed graph of allowed transitions. Same-state "transitions"
  # (e.g. :idle → :idle) are excluded — they're no-ops, not state
  # changes, and should never be logged as such.
  @transitions %{
    # Boot can complete, crash, or be stopped mid-boot.
    booting: [:idle, :crashed, :stopped, :destroying],

    # An idle agent accepts work, can be stopped, can crash, can be destroyed.
    idle: [:thinking, :stopped, :crashed, :destroying],

    # A thinking agent finishes the turn (→ :idle), times out / errors
    # (→ :crashed), or gets stopped mid-turn.
    thinking: [:idle, :stopped, :crashed, :destroying],

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

  # ────────────────────────────────────────────────────────────────
  # Pure transition function (plans/coordination-hardening.md Move #1)
  # ────────────────────────────────────────────────────────────────
  #
  # `step/2` is the total transition function for a ChatAgent. Given
  # the current state and an incoming event, returns the new state +
  # a list of side-effect tuples for the GenServer dispatcher to
  # apply uniformly.
  #
  # Goals:
  #
  #   * One codepath per event. No scattered `%{state | status: ...}`
  #     mutations across 20+ handlers.
  #   * Side effects are DATA, not IO. The step function is pure — it
  #     never broadcasts, never writes ETS, never persists. The
  #     dispatcher does that. This makes the function trivially
  #     unit-testable AND enforces the "if you broadcast, you also
  #     write ETS" invariant by construction.
  #   * Compile-time exhaustiveness. Adding a new event without a
  #     matching clause triggers non-exhaustive-match warnings in the
  #     dispatcher once migration completes.
  #
  # Side-effect vocabulary (extensible — add the atom here AND in
  # `ChatAgent.apply_effect/2`):
  #
  #   * `{:broadcast, topic, message}`
  #   * `{:ets_put, table, key, value}`
  #   * `{:persist_agent}` — append {:agent, ...} to the log
  #   * `{:persist_message, msg}`
  #   * `{:persist_message_update, msg_id, changes}`
  #   * `{:cast_self, message}`
  #
  # Dispatcher continuation:
  #
  #   * `:noreply` — stay alive
  #   * `{:stop, reason}` — terminate after applying effects
  #
  # This module owns only the events being piloted. More clauses
  # land here as migration proceeds.

  @topic "chat_agents"

  @doc """
  Apply an event to the agent state.

  Returns:

    * `{:ok, new_state, side_effects, continuation}`
    * `{:error, reason}` if the event is invalid in the current state

  The four-tuple shape stays consistent across clauses (even when
  `side_effects` is `[]` or `continuation` is `:noreply`) so the
  dispatcher has one uniform pattern.
  """

  # Rename: simplest possible event. No status transition, one
  # broadcast. Perfect pilot for the pattern.
  def step(state, {:rename, new_name}) when is_binary(new_name) do
    new_state = %{state | name: new_name}
    effects = [{:broadcast, @topic, {:chat_agent_renamed, state.id, new_name}}]
    {:ok, new_state, effects, :noreply}
  end

  # Explicit user stop. Enforces the state-machine guard, writes ETS
  # + broadcasts, terminates the GenServer. The imperative
  # backend.stop call stays in the dispatcher — that's session
  # lifecycle, not agent state.
  def step(state, :stop) do
    case transition(state.status, :stopped) do
      {:ok, :stopped} ->
        new_state = %{state | status: :stopped}
        summary = summary_of(new_state)

        effects = [
          {:ets_put, :chat_agents, state.id, summary},
          {:broadcast, @topic, {:chat_agent_stopped, summary}}
        ]

        {:ok, new_state, effects, {:stop, :normal}}

      {:error, _} = err ->
        err
    end
  end

  # summary/1 lives in ChatAgent (it needs the full struct). Register
  # it via :persistent_term at boot to avoid a circular compile
  # dependency. Setting once at startup is cheaper than passing the
  # function through every step call.
  @summary_fn_key {__MODULE__, :summary_fn}

  @doc false
  def configure_summary(fun) when is_function(fun, 1) do
    :persistent_term.put(@summary_fn_key, fun)
  end

  defp summary_of(state) do
    case :persistent_term.get(@summary_fn_key, nil) do
      nil -> raise "ChatAgent.StateMachine.configure_summary/1 not called"
      fun -> fun.(state)
    end
  end
end
