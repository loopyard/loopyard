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
  alias Loopyard.{CanonicalRepo, WorkspaceRegistry, ChatAgent}

  def execute(%{agent_id: agent_id}, _assigns) do
    with %{workspace_id: ws_id} when is_binary(ws_id) <- ChatAgent.get_state(agent_id),
         %{project_id: project_id, branch: branch} when is_binary(project_id) and is_binary(branch) <-
           WorkspaceRegistry.get_workspace(ws_id) do
      action = %{verb: :integrate, project_id: project_id, workspace_id: ws_id, branch: branch}

      case Approvals.request(agent_id, action) do
        {:approve, msg_id} ->
          Approvals.resolve(agent_id, msg_id, %{status: :integrating})

          case CanonicalRepo.integrate(project_id, ws_id, branch) do
            {:ok, _} ->
              Approvals.resolve(agent_id, msg_id, %{status: :integrated})
              {:ok, "Approved. Merged '#{branch}' into main."}

            {:error, reason} ->
              Approvals.resolve(agent_id, msg_id, %{status: :failed, error: inspect(reason)})

              {:error,
               "Merge failed — likely conflicts to resolve on this branch first " <>
                 "(rebase on main, fix, then propose again): #{inspect(reason)}"}
          end

        {:deny, msg_id} ->
          Approvals.resolve(agent_id, msg_id, %{status: :denied})
          {:ok, "The user declined to merge '#{branch}' into main."}

        {:timeout, _} ->
          {:ok, "No response on the merge proposal — not merged."}
      end
    else
      _ -> {:error, "Couldn't resolve the project/branch for this workspace."}
    end
  end
end
