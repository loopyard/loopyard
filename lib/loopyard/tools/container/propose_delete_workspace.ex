defmodule Loopyard.Tools.Container.ProposeDeleteWorkspace do
  use Loopyard.Tool,
    name: "propose_delete_workspace",
    description:
      "Propose DELETING this workspace — removes its env, containers, and the " <>
        "branch's volume. Shows the user an Approve/Deny card and WAITS. This is " <>
        "destructive and only a human can approve it. Use it to clean up AFTER " <>
        "you've merged this branch's work back into main (the code is preserved in " <>
        "main; only the throwaway branch env is removed). Never delete a workspace " <>
        "whose work isn't safely in main.",
    busy_words: ["proposing cleanup", "awaiting approval"],
    params: [
      agent_id: {:string, required: true},
      reason: {:string, description: "Short why — shown on the approval card"}
    ]

  alias Loopyard.Harness.Approvals
  alias Loopyard.{WorkspaceRegistry, ChatAgent}

  def execute(%{agent_id: agent_id} = params, _assigns) do
    with %{workspace_id: ws_id} when is_binary(ws_id) <- ChatAgent.get_state(agent_id),
         %{project_id: project_id, branch: branch} when is_binary(project_id) <-
           WorkspaceRegistry.get_workspace(ws_id) do
      action = %{
        verb: :delete_workspace,
        project_id: project_id,
        workspace_id: ws_id,
        branch: branch,
        reason: Map.get(params, :reason)
      }

      # Queued approval (no blocking, no TTL): post the card and return. The
      # human can approve whenever — on approve the LiveView runs the teardown
      # (deleting this workspace kills this agent, so the agent can't do it
      # itself). The card carries everything the teardown needs.
      Approvals.post(agent_id, action)

      {:ok,
       "I've proposed deleting this workspace — approve the card whenever you're " <>
         "ready (there's no time limit) and it'll be removed. The code stays safe " <>
         "in main; only this branch's env goes away."}
    else
      _ -> {:error, "Couldn't resolve this workspace."}
    end
  end
end
