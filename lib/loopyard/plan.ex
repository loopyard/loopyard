defmodule Loopyard.Plan do
  @moduledoc """
  A harness-agnostic task checklist, owned by Loopyard — not by any harness.

  The plan is **Loopyard state**, the same way the message inbox is (see the
  inbox-vs-turn-execution split). Harnesses that ship a native todo mechanism
  feed it through a thin adapter; harnesses that don't simply leave it empty; a
  future custom harness — or a human, or an Elixir caller — can drive it directly
  with `add/3` + `set_status/3`. The UI, persistence, and multiplayer fan-out all
  read this ONE shape, so the checklist behaves identically no matter who's
  driving, and Loopyard can clear or complete it without asking the model.

  ## Driving it directly from Elixir

      Plan.new()
      |> Plan.add("Wire up click-to-focus")
      |> Plan.add("Re-stack on pin")
      |> Plan.set_status(1, :completed)

  ## Feeding it from a harness adapter

  `apply_event/2` folds one NEUTRAL plan event onto the plan:

    * `{:add, subject, opts}` — append a task (`opts[:active_form]` optional)
    * `{:set_status, id, status}` — move a task to `:pending | :in_progress | :completed`
    * `:clear` — drop every task
    * `:complete_all` — mark everything done

  A harness adapter's only job is to translate its native signal into those
  events. The Claude adapter lives in `Loopyard.Harness.Claude.Plan`; a Codex or
  ACP adapter would be the same shape. `apply_events/2` folds a whole list.
  """

  @statuses [:pending, :in_progress, :completed]

  @type status :: :pending | :in_progress | :completed
  @type task :: %{
          id: pos_integer(),
          subject: String.t(),
          active_form: String.t() | nil,
          status: status()
        }
  @type t :: [task()]
  @type event ::
          {:add, String.t(), keyword()}
          | {:set_status, pos_integer(), status()}
          | :clear
          | :complete_all

  @doc "An empty plan."
  @spec new() :: t()
  def new, do: []

  @doc "Append a task. `opts[:active_form]` is the gerund shown while it's active."
  @spec add(t(), String.t(), keyword()) :: t()
  def add(plan, subject, opts \\ []) when is_list(plan) and is_binary(subject) do
    plan ++
      [
        %{
          id: next_id(plan),
          subject: subject,
          active_form: opts[:active_form],
          status: :pending
        }
      ]
  end

  @doc "Set a task's status by id. Unknown id or status is a no-op (never crashes)."
  @spec set_status(t(), pos_integer(), status()) :: t()
  def set_status(plan, id, status) when is_list(plan) and status in @statuses do
    Enum.map(plan, fn t -> if t.id == id, do: %{t | status: status}, else: t end)
  end

  def set_status(plan, _id, _status), do: plan

  @doc "Drop every task."
  @spec clear(t()) :: t()
  def clear(plan) when is_list(plan), do: []

  @doc "Mark every task completed."
  @spec complete_all(t()) :: t()
  def complete_all(plan) when is_list(plan),
    do: Enum.map(plan, &%{&1 | status: :completed})

  @doc "Fold one neutral plan event onto the plan. Unknown events pass through."
  @spec apply_event(t(), event() | any()) :: t()
  def apply_event(plan, {:add, subject, opts}) when is_binary(subject),
    do: add(plan, subject, opts)

  def apply_event(plan, {:set_status, id, status}), do: set_status(plan, id, status)
  def apply_event(plan, :clear), do: clear(plan)
  def apply_event(plan, :complete_all), do: complete_all(plan)
  def apply_event(plan, _other) when is_list(plan), do: plan

  @doc "Fold a list of events left-to-right."
  @spec apply_events(t(), [event()]) :: t()
  def apply_events(plan, events) when is_list(events),
    do: Enum.reduce(events, plan, &apply_event(&2, &1))

  @doc "`%{done: n, total: n}` — for the progress counter."
  @spec counts(t()) :: %{done: non_neg_integer(), total: non_neg_integer()}
  def counts(plan), do: %{done: Enum.count(plan, &(&1.status == :completed)), total: length(plan)}

  @doc "True when there's at least one task and all are completed."
  @spec all_done?(t()) :: boolean()
  def all_done?(plan), do: plan != [] and Enum.all?(plan, &(&1.status == :completed))

  @doc "The task currently in progress, or nil."
  @spec active(t()) :: task() | nil
  def active(plan), do: Enum.find(plan, &(&1.status == :in_progress))

  @doc """
  Parse a free-form status string into an atom. Tolerant of the spellings
  different harnesses use (`in_progress` / `in-progress` / `active`,
  `done`/`complete`/`completed`). Anything unrecognized → `:pending`.
  """
  @spec parse_status(any()) :: status()
  def parse_status(s) when is_atom(s) and s in @statuses, do: s

  def parse_status(s) when is_binary(s) do
    case s |> String.downcase() |> String.replace("-", "_") do
      "completed" -> :completed
      "complete" -> :completed
      "done" -> :completed
      "in_progress" -> :in_progress
      "active" -> :in_progress
      "running" -> :in_progress
      _ -> :pending
    end
  end

  def parse_status(_), do: :pending

  defp next_id([]), do: 1
  defp next_id(plan), do: (plan |> Enum.map(& &1.id) |> Enum.max()) + 1
end
