defmodule Loopyard.Turn do
  @moduledoc """
  The pure, harness-agnostic turn-taking state machine.

  "Turn-taking" is the protocol of *whose turn it is* — the human or the agent —
  and what happens to the human's input while the agent holds the turn. This is
  the same model ACP enforces (one `session/prompt` at a time, streamed
  `session/update`s, `session/cancel` to interrupt) and the one a custom harness
  must honor. Loopyard owns this machine; the harness only drives it via
  normalized events and executes the side-effects it returns.

  ## Phases

    * `:human` — idle. The human holds the turn; a `:send` starts the agent's turn.
    * `:agent` — the agent holds the turn, streaming output. A `:send` here PARKS
      in the queue (it doesn't interleave into the stream).
    * `:agent_blocked` — the agent yielded mid-turn for human input (a question OR
      a permission request — one phase, typed payload in `blocked_on`). An
      `:answer` resumes the turn.

  ## Contract

  `step(turn, event) :: {:ok, turn, [effect]} | {:error, reason}` — a pure
  function. It never performs I/O; it returns **effects** the caller runs:

    * `{:start_turn, prompt}` — send `prompt` to the harness to begin a turn
      (also how a parked flurry drains — batched into one prompt on completion).
    * `{:answer_input, id, decision}` — reply to the harness's pending input
      request (ACP `session/request_permission` response; the SDK's ask/approval
      broker reply).
    * `:cancel_turn` — interrupt the active turn (ACP `session/cancel`; SDK stop).
    * `{:queued, text}` — a message was parked (UI feedback only).

  Invalid transitions return `{:error, {:invalid_transition, phase, event}}` so
  the caller can log + ignore rather than crash.
  """

  @type phase :: :human | :agent | :agent_blocked
  @type block :: %{kind: :question | :permission, id: term(), payload: map()}

  @type t :: %__MODULE__{
          phase: phase(),
          queue: [String.t()],
          blocked_on: block() | nil
        }

  defstruct phase: :human, queue: [], blocked_on: nil

  @type effect ::
          {:start_turn, String.t()}
          | {:answer_input, term(), term()}
          | :cancel_turn
          | {:queued, String.t()}

  @type event ::
          {:send, String.t()}
          | {:input_requested, :question | :permission, term(), map()}
          | {:answer, term(), term()}
          | :turn_complete
          | :interrupt
          | :clear_queue
          | {:remove_queued, non_neg_integer()}

  @doc "A fresh machine: the human holds the turn, nothing queued."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Advance the machine. Pure. See the moduledoc for the contract."
  @spec step(t(), event()) :: {:ok, t(), [effect()]} | {:error, term()}

  # --- :send — start a turn, or park while the agent holds it ---

  def step(%__MODULE__{phase: :human} = t, {:send, text}) when is_binary(text) do
    {:ok, %{t | phase: :agent}, [{:start_turn, text}]}
  end

  def step(%__MODULE__{phase: phase} = t, {:send, text})
      when phase in [:agent, :agent_blocked] and is_binary(text) do
    {:ok, %{t | queue: t.queue ++ [text]}, [{:queued, text}]}
  end

  # --- agent yields mid-turn for human input ---

  def step(%__MODULE__{phase: :agent} = t, {:input_requested, kind, id, payload})
      when kind in [:question, :permission] do
    {:ok, %{t | phase: :agent_blocked, blocked_on: %{kind: kind, id: id, payload: payload}}, []}
  end

  # --- human answers the blocking request (must match the live request id) ---

  def step(%__MODULE__{phase: :agent_blocked, blocked_on: %{id: id}} = t, {:answer, id, decision}) do
    {:ok, %{t | phase: :agent, blocked_on: nil}, [{:answer_input, id, decision}]}
  end

  def step(%__MODULE__{phase: :agent_blocked}, {:answer, _stale_id, _decision}) do
    # Answering a request that's no longer the live one (replaced/expired).
    {:error, :stale_answer}
  end

  # --- turn completes: settle to :human, or batch-drain a parked flurry ---

  def step(%__MODULE__{phase: phase} = t, :turn_complete) when phase in [:agent, :agent_blocked] do
    settle(%{t | phase: :human, blocked_on: nil})
  end

  # --- interrupt (Stop): cancel the turn, drop the queue, hand control back ---

  def step(%__MODULE__{phase: phase} = t, :interrupt) when phase in [:agent, :agent_blocked] do
    {:ok, %{t | phase: :human, queue: [], blocked_on: nil}, [:cancel_turn]}
  end

  # --- queue management (valid in any phase, never changes whose turn it is) ---

  def step(%__MODULE__{} = t, :clear_queue), do: {:ok, %{t | queue: []}, []}

  def step(%__MODULE__{} = t, {:remove_queued, i}) when is_integer(i) and i >= 0 do
    {:ok, %{t | queue: List.delete_at(t.queue, i)}, []}
  end

  # --- anything else is an invalid transition for the current phase ---

  def step(%__MODULE__{phase: phase}, event) do
    {:error, {:invalid_transition, phase, event}}
  end

  # Landing on :human with a non-empty queue means messages were parked while the
  # agent worked — batch the whole flurry into ONE next turn (the agent "looks at
  # the flurry" together) rather than firing a turn per message.
  defp settle(%__MODULE__{phase: :human, queue: [_ | _] = q} = t) do
    {:ok, %{t | phase: :agent, queue: []}, [{:start_turn, batch_prompt(q)}]}
  end

  defp settle(%__MODULE__{} = t), do: {:ok, t, []}

  @doc """
  Format a parked flurry into one prompt. A single message goes through as-is; a
  flurry is FRAMED as an ordered sequence so the agent treats later messages as
  refinements/corrections of earlier ones (not three independent demands). The
  single source of truth for the batch format — used by the turn machine and the
  live ChatAgent drain.
  """
  @spec batch_prompt([String.t()]) :: String.t()
  def batch_prompt([single]), do: single

  def batch_prompt(messages) when is_list(messages) do
    numbered =
      messages
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {m, i} -> "#{i}. #{m}" end)

    "You sent #{length(messages)} messages while I was working, in order:\n" <>
      numbered <>
      "\n\nHandle them together; later ones may refine or correct earlier ones."
  end
end
