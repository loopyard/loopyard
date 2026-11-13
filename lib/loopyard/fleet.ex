defmodule Loopyard.Fleet do
  @moduledoc """
  The two moves on an agent that stopped without asking (#119), shared by the
  inbox card and the chief of staff's `agent action=continue`:

    * `continue/1` — wake the agent if it's asleep and re-drive its unanswered
      prompts (`ChatAgent.Interrupted`), settling its interrupted item.
    * `dismiss/2` — wave the item away; for an interruption that also clears
      the mark, so it doesn't come back at the next sweep or boot.

  The watching itself is `Loopyard.Fleet.Watch`; the conditions and their
  words are `Loopyard.Fleet.Conditions`.
  """

  alias Loopyard.{Agents, Notifications}
  alias Loopyard.ChatAgent.Interrupted
  alias Loopyard.Fleet.Conditions

  @doc """
  Continue an agent: wake it, re-drive what it was doing. `:ok` when it is
  now working on it (or already was), `{:error, reason}` otherwise.
  """
  @spec continue(String.t()) :: :ok | {:error, term()}
  def continue(agent_id) when is_binary(agent_id) do
    with :ok <- Agents.ensure_running(agent_id),
         result when result in [:ok, {:error, :busy}] <- call(agent_id, :continue) do
      Notifications.settle(Conditions.item_id(agent_id, :interrupted), :continued)
      :ok
    else
      {:error, :nothing_to_continue} ->
        Notifications.settle(Conditions.item_id(agent_id, :interrupted), :answered)
        {:error, :nothing_to_continue}

      {:error, _} = error ->
        error

      other ->
        {:error, other}
    end
  end

  @doc "Dismiss a stuck item; an interruption's mark goes with it."
  @spec dismiss(String.t(), String.t() | nil) :: :ok
  def dismiss(item_id, by \\ nil) when is_binary(item_id) do
    case Notifications.get(item_id) do
      %{kind: :stuck, agent_id: aid, meta: %{condition: :interrupted}} -> clear_mark(aid)
      _ -> :ok
    end

    Notifications.dismiss(item_id, by)
    :ok
  end

  defp clear_mark(aid) do
    if Agents.alive?(aid) do
      call(aid, :dismiss)
    else
      if row = Agents.get(aid), do: Interrupted.clear_row(row)
    end

    :ok
  end

  defp call(aid, action) do
    GenServer.call(
      {:via, Registry, {Loopyard.ChatAgentRegistry, aid}},
      {:interrupted, action},
      5_000
    )
  catch
    :exit, _ -> {:error, :unavailable}
  end
end
