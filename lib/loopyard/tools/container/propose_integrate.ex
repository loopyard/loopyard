defmodule Loopyard.Tools.Container.ProposeIntegrate do
  use Loopyard.Tool,
    name: "propose_integrate",
    description:
      "Propose merging THIS branch's work back into the project's main branch. " <>
        "Shows the user an Approve/Deny card and WAITS. On approval the branch is " <>
        "rebased on main and merged — a clean, human-approved integration into a " <>
        "main that stays green. Use when the work on this branch is done and ready " <>
        "to land. Only a human can merge to main (guardrail). If the merge hits " <>
        "conflicts it fails cleanly — resolve them on this branch, then propose again.",
    busy_words: ["proposing a merge", "awaiting approval"],
    params: [
      agent_id: {:string, required: true}
    ]

  alias Loopyard.Harness.Approvals
  alias Loopyard.{WorkspaceRegistry, ChatAgent}

  def execute(%{agent_id: agent_id}, _assigns) do
    with %{workspace_id: ws_id} when is_binary(ws_id) <- ChatAgent.get_state(agent_id),
         %{project_id: project_id, branch: branch}
         when is_binary(project_id) and is_binary(branch) <-
           WorkspaceRegistry.get_workspace(ws_id) do
      action = %{verb: :integrate, project_id: project_id, workspace_id: ws_id, branch: branch}

      # Queued approval (no blocking, no TTL): post the card and return. On
      # approve, the LiveView runs `Approvals.run/3`, which rebases + merges this
      # branch into main and streams the outcome into the card.
      Approvals.post(agent_id, action)

      {:ok,
       "I've proposed merging '#{branch}' into main. Approve the card whenever " <>
         "you're ready — no time limit — and I'll rebase + merge it. If it hits " <>
         "conflicts it fails cleanly and you can resolve them on this branch, then " <>
         "propose again."}
    else
      _ -> {:error, "Couldn't resolve the project/branch for this workspace."}
    end
  end
end
