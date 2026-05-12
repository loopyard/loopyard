defmodule Loopyard.Service.StateMachine do
  @moduledoc """
  State graph for a single service (one container in the compose cluster).

  Four states:

      :stopped  — container is not running
      :starting — `docker compose up <svc>` or restart in flight
      :started  — container is running
      :stopping — `docker compose stop <svc>` in flight

  Transitions:

      :stopped  →  :starting  (user clicks Start on the service)
      :starting →  :started   (container came up)
      :starting →  :stopped   (compose up failed)
      :started  →  :stopping  (user clicks Stop on the service)
      :started  →  :stopped   (container exited on its own — crash, OOM)
      :stopping →  :stopped   (container stopped cleanly)
      :stopping →  :started   (stop failed — container still running)

  Pure validation; callers keep `{state, entered_at}` themselves.

  Kept separate from `Loopyard.Cluster.StateMachine` even though the
  graph shape overlaps — cluster- and service-level actions are driven
  by distinct commands and error conditions, so merging the modules
  would just mean typing out the same states in a single file with no
  actual reuse.
  """

  @states [:stopped, :starting, :started, :stopping]

  @transitions %{
    stopped: [:starting],
    starting: [:started, :stopped],
    started: [:stopping, :stopped],
    stopping: [:stopped, :started]
  }

  @doc "Every possible state."
  def states, do: @states

  @doc "Map of `from → [allowed_to]`."
  def transitions, do: @transitions

  @doc """
  Check whether `from → to` is a legal transition.

  Same-state moves return `true` — they're no-ops, the caller isn't
  actually changing state.
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
