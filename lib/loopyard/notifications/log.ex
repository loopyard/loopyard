defmodule Loopyard.Notifications.Log do
  @moduledoc """
  The notifications store's OWN durable log — `<LOOPYARD_HOME>/notifications.log`.

  Its own, and not a ride on an agent's log, for two reasons found in review:
  a card resolved while its agent's GenServer is down is patched in ETS and
  never reaches the agent log, and `Persistence.state_log_path/1` has no
  destination at all for a cross-agent store. Same on-disk shape as
  `Loopyard.AgentLog` (length-prefixed zlib ETF records behind a meta header),
  reusing its primitives, with two record types:

    * `{:item, %Item{}}` — an upsert; the newest record for an id wins.
    * `{:snapshot, [%Item{}]}` — a compaction point: the state as of then.

  Compaction rewrites the file as one snapshot of what's worth keeping (every
  open item + a bounded tail of settled ones) once the record count grows
  past `@compact_after`, so replay stays bounded on a long-lived install.
  """

  alias Loopyard.AgentLog
  alias Loopyard.Notifications.Item

  @version 1
  @compact_after 5_000

  @doc "The log path under the Loopyard home."
  def path, do: Path.join(Loopyard.Workspace.home_dir(), "notifications.log")

  @doc "Records before a compaction is due."
  def compact_after, do: @compact_after

  @doc """
  Append an item upsert. Disk failures (full, unwritable) are swallowed into
  telemetry, never raised — losing durability of one item must not take the
  store down.
  """
  @spec append(Item.t()) :: :ok
  def append(%Item{} = item) do
    AgentLog.append({:item, item}, log_path: path(), version: @version)
    :ok
  rescue
    e ->
      :telemetry.execute(
        [:loopyard, :persistence, :error],
        %{count: 1},
        %{log: :notifications, error: Exception.message(e)}
      )

      :ok
  end

  @doc """
  Replay the log into `{items_by_id, record_count}`. A missing log is an
  empty store; an unreadable one is logged and treated as empty (the reconcile
  sweep rebuilds open decisions from the cards anyway).
  """
  @spec replay() :: {%{optional(String.t()) => Item.t()}, non_neg_integer()}
  def replay do
    case AgentLog.read_events(log_path: path()) do
      {:ok, events} ->
        Enum.reduce(events, {%{}, 0}, fn
          {:item, %Item{id: id} = item}, {acc, n} -> {Map.put(acc, id, item), n + 1}
          {:snapshot, items}, {_acc, n} -> {Map.new(items, &{&1.id, &1}), n + 1}
          _, acc -> acc
        end)

      {:error, reason} ->
        Loopyard.EventLog.error("notifications", "log unreadable: #{inspect(reason)}")
        {%{}, 0}
    end
  rescue
    e ->
      Loopyard.EventLog.error("notifications", "log replay failed: #{Exception.message(e)}")
      {%{}, 0}
  end

  @doc """
  Rewrite the log as a single snapshot of `items`. Written to a sibling temp
  file and renamed over, so a crash mid-write leaves the old log intact.
  """
  @spec compact([Item.t()]) :: :ok
  def compact(items) do
    p = path()
    tmp = p <> ".compacting"
    File.mkdir_p!(Path.dirname(p))
    File.rm(tmp)
    AgentLog.ensure_meta_header(tmp, @version)
    AgentLog.write_record(tmp, {:snapshot, items})
    File.rename!(tmp, p)
    :ok
  rescue
    e ->
      :telemetry.execute(
        [:loopyard, :persistence, :error],
        %{count: 1},
        %{log: :notifications, error: Exception.message(e)}
      )

      :ok
  end
end
