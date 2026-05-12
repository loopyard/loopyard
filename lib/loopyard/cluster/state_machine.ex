defmodule Loopyard.Cluster.StateMachine do
  @moduledoc """
  State graph for a workspace's Docker Compose cluster.

  A cluster moves through four states:

      :stopped  — no containers running
      :starting — `docker compose up` is in flight
      :started  — at least one container is running
      :stopping — `docker compose down` is in flight

  The transitions are:

      :stopped  →  :starting  (user clicks Start)
      :starting →  :started   (containers came up)
      :starting →  :stopped   (compose up failed — back to square one)
      :started  →  :stopping  (user clicks Stop)
      :stopping →  :stopped   (all containers down)
      :stopping →  :started   (compose down failed — still running)

  Pure validation. No storage, no timestamps here — callers carry
  `{state, entered_at}` pairs (or equivalent) and use this module to
  gate moves.

  See `Loopyard.Service.StateMachine` for the per-service version
  (same graph, different error-state semantics for the "Crashed"
  situation where a container exits non-zero on its own).
  """

  @states [:stopped, :starting, :started, :stopping]

  @transitions %{
    stopped: [:starting],
    starting: [:started, :stopped],
    started: [:stopping],
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
  Validate `from → to`. Returns `{:ok, to}` on success,
  `{:error, {:invalid_transition, from, to}}` on illegal moves.
  """
  def transition(from, to) do
    if allowed_transition?(from, to) do
      {:ok, to}
    else
      {:error, {:invalid_transition, from, to}}
    end
  end
end
