defmodule Loopyard.Operator.Digest do
  @moduledoc """
  The operator's completion digest — a bounded ring of "what just finished"
  across every workspace, so the operator (chief of staff) learns headlines
  WITHOUT any of it living in its LLM context.

  It rides the existing `Events.Activity` backbone (which already mirrors every
  agent's `StatusChanged` cross-project): a workspace agent's turn ending
  (`kind: :status`, `summary: "idle"`) appends one compact entry. Consecutive
  idles from the same agent are deduped. The `recent_activity` MCP tool reads the
  ring directly from ETS (`:operator_digest`, owned by `StateKeeper`) — the
  operator pulls it on its own cadence; nothing is pushed into its context.

  Config-gated (`:operator_digest_enabled?`, off in test) — like `ChangeCounts`,
  it subscribes to live PubSub, which tests don't want.
  """
  use GenServer
  require Logger

  alias Loopyard.Events

  @table :operator_digest
  @max 100

  # --- Read API (ETS-only; safe to call from anywhere, incl. the MCP tool) ---

  @doc "Recent cross-workspace completions, NEWEST first (up to `limit`)."
  @spec recent(pos_integer()) :: [map()]
  def recent(limit \\ 20) when is_integer(limit) and limit > 0 do
    :ets.tab2list(@table)
    |> Enum.sort_by(fn {seq, _} -> seq end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {_seq, entry} -> entry end)
  rescue
    _ -> []
  end

  # --- Lifecycle ---

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if enabled?(), do: Events.Activity.subscribe_global()
    {:ok, %{seq: 0, last: nil}}
  end

  # A workspace agent finished a turn (idle). Operator-only agents have no
  # workspace_id, so those don't land in the digest.
  @impl true
  def handle_info(
        %Events.Activity.Event{kind: :status, summary: "idle", workspace_id: ws} = e,
        state
      )
      when is_binary(ws) do
    key = {e.agent_id, :idle}

    if state.last == key do
      # Dedupe a repeated idle from the SAME agent back-to-back (no new turn).
      {:noreply, state}
    else
      seq = state.seq + 1

      entry = %{
        agent_id: e.agent_id,
        agent_name: e.agent_name,
        workspace_id: e.workspace_id,
        project_id: e.project_id,
        summary: "finished a turn",
        at: e.at
      }

      :ets.insert(@table, {seq, entry})
      if seq > @max, do: :ets.delete(@table, seq - @max)
      {:noreply, %{state | seq: seq, last: key}}
    end
  end

  def handle_info(%Events.Activity.Event{}, state), do: {:noreply, state}

  # Catchall (project rule): unknown messages never crash the GenServer.
  def handle_info(msg, state) do
    Logger.warning("[Operator.Digest] unhandled info: #{inspect(msg, limit: 100)}")
    {:noreply, state}
  end

  defp enabled?, do: Application.get_env(:loopyard, :operator_digest_enabled?, true)
end
