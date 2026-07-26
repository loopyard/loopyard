defmodule LoopyardWeb.Live.ApprovalActions do
  @moduledoc """
  The ONE Approve/Deny implementation shared by every surface that renders an
  approval card (workspace chat, message permalink, the Reviewer). Speaks BOTH
  approval models:

    * blocking — a live waiter (`Approvals.decide/2`) takes the decision;
    * queued — the card is durable: deny resolves it, approve flips it to its
      verb-matched working state and runs the action off the card in a
      supervised Task (`Approvals.run/3` streams progress into the card).
  """

  alias Loopyard.Harness.Approvals

  @spec decide(String.t(), String.t(), :approve | :deny) :: :ok
  def decide(agent_id, approval_id, decision) do
    card =
      Enum.find(
        (Loopyard.ChatAgent.get_state(agent_id) || %{})[:messages] || [],
        &(&1[:approval_id] == approval_id)
      )

    case Approvals.decide(approval_id, decision) do
      :ok ->
        :ok

      {:error, :not_found} when not is_nil(card) and decision == :deny ->
        Approvals.resolve(agent_id, card.id, %{status: :denied})
        :ok

      {:error, :not_found} when not is_nil(card) ->
        transient =
          case card[:action][:verb] do
            v when v in [:delete_workspace, :delete_project] -> :deleting
            v when v in [:rename_workspace, :rename_project] -> :renaming
            :integrate -> :integrating
            _ -> :creating
          end

        Loopyard.ChatAgent.update_message(agent_id, card.id, &Map.put(&1, :status, transient))

        Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
          Approvals.run(agent_id, card.id, card[:action])
        end)

        :ok

      _ ->
        :ok
    end
  end
end
