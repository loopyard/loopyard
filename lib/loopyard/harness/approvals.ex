defmodule Loopyard.Harness.Approvals do
  @moduledoc """
  The human-approval broker for boundary-crossing actions (creating a branch
  workspace = the "agent spawned a shitload of workspaces" guardrail).

  Same blocking-waiter pattern as `Loopyard.Harness.Questions`: the agent calls
  a tool (`propose_fork`) which calls `request/2` with an `action` map; the
  broker appends a `role: :approval` message (persisted + broadcast → the whole
  room sees the Approve/Deny card) and blocks until a human decides. `decide/2`
  (from the LiveView) delivers the decision to the blocked caller.

  The tool owns the card's lifecycle after the decision — call `resolve/3` to
  flip it to `:approved` (with the new workspace) / `:denied` / `:failed`, which
  persists + broadcasts to everyone.
  """
  alias Loopyard.ChatAgent

  @table :harness_approvals
  @timeout_ms 30 * 60 * 1000

  @doc """
  Post an approval card for `action` and BLOCK until a human decides. Returns
  `{:approve | :deny | :timeout, msg_id}` — `msg_id` lets the caller `resolve/3`
  the card with the outcome.
  """
  @spec request(String.t(), map()) :: {:approve | :deny | :timeout, String.t() | nil}
  def request(agent_id, action) when is_binary(agent_id) and is_map(action) do
    id = gen_id()

    msg =
      ChatAgent.append_message_ets(agent_id, %{
        role: :approval,
        approval_id: id,
        action: action,
        status: :pending,
        timestamp: DateTime.utc_now()
      })

    msg_id = msg && msg.id
    :ets.insert(@table, {id, %{agent_id: agent_id, msg_id: msg_id, waiter: self()}})

    receive do
      {:decided, ^id, decision} ->
        :ets.delete(@table, id)
        {decision, msg_id}
    after
      @timeout_ms ->
        :ets.delete(@table, id)
        {:timeout, msg_id}
    end
  end

  @doc "Deliver a human's approve/deny. Called from the LiveView."
  @spec decide(String.t(), :approve | :deny) :: :ok | {:error, :not_found}
  def decide(id, decision) when is_binary(id) and decision in [:approve, :deny] do
    case :ets.lookup(@table, id) do
      [{^id, %{waiter: pid}}] when is_pid(pid) ->
        send(pid, {:decided, id, decision})
        :ok

      _ ->
        {:error, :not_found}
    end
  end

  @doc "Update the approval card with the outcome (persisted + broadcast)."
  @spec resolve(String.t(), String.t() | nil, map()) :: :ok
  def resolve(_agent_id, nil, _changes), do: :ok

  def resolve(agent_id, msg_id, changes) do
    ChatAgent.update_message(agent_id, msg_id, fn m -> Map.merge(m, changes) end)
    :ok
  end

  @spec pending?(String.t()) :: boolean()
  def pending?(id), do: :ets.member(@table, id)

  defp gen_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
