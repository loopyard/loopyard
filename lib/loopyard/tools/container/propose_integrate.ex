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

  # Integration merges the workspace's branch INTO canonical `main`
  # (CanonicalRepo.integrate). Proposing to integrate `main` itself is a
  # self-merge that can never validly complete — it just leaves a "wants
  # approval" card stuck forever. Refuse at the source.
  @integration_target "main"

  def execute(%{agent_id: agent_id}, _assigns) do
    with %{workspace_id: ws_id} when is_binary(ws_id) <- ChatAgent.get_state(agent_id),
         %{project_id: project_id, branch: branch}
         when is_binary(project_id) and is_binary(branch) <-
           WorkspaceRegistry.get_workspace(ws_id),
         :ok <- refuse_self_merge(branch) do
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
      {:error, :self_merge} ->
        {:error,
         "This workspace is already on '#{@integration_target}' — there's nothing to integrate " <>
           "(you'd be merging main into itself). Integration is for landing a BRANCH's work " <>
           "into main; create a fork/branch workspace, do the work there, then propose from it."}

      _ ->
        {:error, "Couldn't resolve the project/branch for this workspace."}
    end
  end

  defp refuse_self_merge(branch) do
    if branch == @integration_target, do: {:error, :self_merge}, else: :ok
  end
end
