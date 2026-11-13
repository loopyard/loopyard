defmodule Loopyard.AccountLimits do
  @moduledoc """
  Plan limits belong to the ACCOUNT, not the agent. A flat-rate plan caps usage
  per time window for everything that bills it, so when one agent learns that
  `brad`'s Claude plan is spent until 14:05, every other agent on `brad`'s
  Claude credential is spent too — it shouldn't have to burn a turn to find out.

  This is that shared knowledge: one row per `{identity, harness}` holding
  "limited until", written by whichever agent hears the refusal
  (`ChatAgent.PlanLimit`), read by every agent before it starts a turn, by the
  failover picker, by the chief of staff's `overview` and by the workstation
  page. ETS (`:account_limits`, owned by `Loopyard.StateKeeper`), node-local and
  deliberately not persisted: after a restart the first refused turn re-learns
  it, which costs one turn per account rather than a stale row that strands
  every agent.

  A refusal without a reset time (the adapter died on "Rate limit reached"
  with nothing structured) is recorded `known: false` for
  `:account_limit_unknown_reset_ms` (default 15 min): long enough to stop a
  failover bouncing back onto it, short enough that a guess never strands work.
  """

  alias Loopyard.Harness.Catalog

  @table :account_limits

  @type key :: {String.t(), atom()}
  @type row :: %{
          identity: String.t(),
          harness: atom(),
          until_ms: integer(),
          known: boolean(),
          type: String.t() | nil,
          learned_from: String.t() | nil
        }

  @doc "How long an unknown-reset refusal is assumed to last."
  def unknown_reset_ms,
    do: Application.get_env(:loopyard, :account_limit_unknown_reset_ms, 15 * 60_000)

  @doc """
  Record that `identity`'s `harness` plan refused a turn. `until_ms` nil means
  the refusal carried no reset time. A later known reset never shortens an
  existing one: two agents hearing the same limit can only extend it.
  """
  @spec mark(String.t(), atom() | String.t() | nil, integer() | nil, map()) :: row()
  def mark(identity, harness, until_ms, meta \\ %{}) when is_binary(identity) do
    key = key(identity, harness)
    now = now()
    known? = is_integer(until_ms) and until_ms > now
    until = if known?, do: until_ms, else: now + unknown_reset_ms()

    fresh = %{
      identity: identity,
      harness: elem(key, 1),
      until_ms: until,
      known: known?,
      type: meta[:type],
      learned_from: meta[:agent_id]
    }

    row = keep(get_row(key), fresh)
    :ets.insert(@table, {key, row})
    row
  end

  # A reset the adapter told us beats a guess; between two of the same kind,
  # the later one wins (two agents hearing one limit can only extend it).
  defp keep(nil, fresh), do: fresh
  defp keep(%{known: true} = old, %{known: false}), do: old
  defp keep(%{known: false}, %{known: true} = fresh), do: fresh
  defp keep(old, fresh), do: if(old.until_ms >= fresh.until_ms, do: old, else: fresh)

  @doc "The live row for an account, or nil when it isn't limited (expired rows are dropped)."
  @spec get(String.t() | nil, atom() | String.t() | nil) :: row() | nil
  def get(identity, harness) when is_binary(identity), do: get_row(key(identity, harness))
  def get(_identity, _harness), do: nil

  @doc "When the account's plan frees up again, or nil when it isn't limited."
  @spec limited_until(String.t() | nil, atom() | String.t() | nil) :: integer() | nil
  def limited_until(identity, harness) do
    case get(identity, harness) do
      %{until_ms: until} -> until
      nil -> nil
    end
  end

  @doc "Is the account known to be at its plan limit right now?"
  def limited?(identity, harness), do: limited_until(identity, harness) != nil

  @doc "The window reset (or a turn on the account was allowed): forget the limit."
  def clear(identity, harness) when is_binary(identity) do
    :ets.delete(@table, key(identity, harness))
    :ok
  rescue
    _ -> :ok
  end

  def clear(_identity, _harness), do: :ok

  @doc "Every live limit on one account, by harness."
  @spec for_identity(String.t()) :: [row()]
  def for_identity(identity), do: Enum.filter(all(), &(&1.identity == identity))

  @doc "Every live limit."
  @spec all() :: [row()]
  def all do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {key, _row} -> get_row(key) end)
    |> Enum.reject(&is_nil/1)
  rescue
    _ -> []
  end

  @doc ~s(Wall-clock form of a reset: "14:05" today, "Thu 14:05" further out.)
  @spec clock(integer() | nil) :: String.t() | nil
  def clock(ms) when is_integer(ms) do
    local = ms |> :calendar.system_time_to_local_time(:millisecond) |> NaiveDateTime.from_erl!()
    {today, _} = :calendar.local_time()

    if NaiveDateTime.to_date(local) == Date.from_erl!(today),
      do: Calendar.strftime(local, "%H:%M"),
      else: Calendar.strftime(local, "%a %H:%M")
  end

  def clock(_), do: nil

  @doc false
  def clear_all do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    _ -> :ok
  end

  defp get_row(key) do
    case :ets.lookup(@table, key) do
      [{^key, %{until_ms: until} = row}] ->
        if until > now() do
          row
        else
          :ets.delete(@table, key)
          nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp key(identity, harness), do: {identity, Catalog.fetch(harness).id}

  defp now, do: System.system_time(:millisecond)
end
