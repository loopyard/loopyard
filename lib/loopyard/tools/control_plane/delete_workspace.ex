defmodule Loopyard.Tools.ControlPlane.DeleteWorkspace do
  @moduledoc """
  The operator proposes DELETING a workspace — consent-gated, because it's
  destructive (removes the branch's env, containers, and volume; the code stays
  in main). Uses the operator's blocking approval model: post an Approve/Deny
  card and WAIT; on approve the operator itself runs the teardown (it survives —
  it's deleting ANOTHER workspace, not its own) and resolves the card. Reuses the
  same `Workspace.Destructor` teardown as `propose_delete_workspace`.
  """
  use Loopyard.Tool,
    name: "delete_workspace",
    description:
      "Propose DELETING a workspace — removes its env, containers, and volume " <>
        "(the code stays in main). Shows the user an Approve/Deny card and WAITS; " <>
        "only a human can approve. `target` is a workspace id/name. Use to clean " <>
        "up a throwaway branch workspace once its work is merged.",
    busy_words: ["proposing cleanup", "awaiting approval"],
    params: [
      agent_id: {:string, required: true},
      target: {:string, required: true, description: "Workspace id/name to delete."},
      reason: {:string, description: "Short why — shown on the approval card."}
    ]

  alias Loopyard.Harness.Approvals
  alias Loopyard.{WorkspaceRegistry, Tools.ControlPlane}

  def execute(%{agent_id: operator_id, target: target} = params, _assigns) do
    with {:ok, ws_id} <- ControlPlane.resolve_workspace(target),
         %{} = ws <- WorkspaceRegistry.get_workspace(ws_id) do
      action = %{
        verb: :delete_workspace,
        project_id: ws[:project_id],
        workspace_id: ws_id,
        branch: ws[:branch] || ws[:name] || ws_id,
        name: ws[:name],
        reason: params[:reason]
      }

      case Approvals.request(operator_id, action) do
        {:approve, msg_id} ->
          Approvals.resolve(operator_id, msg_id, %{status: :deleting})
          Loopyard.Workspace.Destructor.destroy(ws_id)
          Approvals.resolve(operator_id, msg_id, %{status: :deleted})
          {:ok, "Deleted workspace #{ws[:name] || ws_id}."}

        {:deny, _} ->
          {:ok, "The user declined to delete #{ws[:name] || ws_id}."}

        {:timeout, _} ->
          {:ok, "No response on the delete proposal — #{ws[:name] || ws_id} was not deleted."}
      end
    else
      _ ->
        {:error, "Couldn't resolve workspace '#{target}'. Call overview to see valid ids/names."}
    end
  rescue
    e -> {:error, "Delete failed: #{inspect(e)}"}
  end
end
