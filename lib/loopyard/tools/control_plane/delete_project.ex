defmodule Loopyard.Tools.ControlPlane.DeleteProject do
  @moduledoc """
  The operator proposes DELETING an entire project — consent-gated, because it's
  destructive and cascading: `ProjectRegistry.remove_project/1` destroys ALL the
  project's workspaces (envs, containers, volumes, on-disk state). Blocking
  approval model, same as `delete_workspace`: post an Approve/Deny card and WAIT;
  on approve the operator runs the teardown and resolves the card.
  """
  use Loopyard.Tool,
    name: "delete_project",
    description:
      "Propose DELETING an ENTIRE project — destroys ALL its workspaces (envs, " <>
        "containers, volumes). Irreversible. Shows the user an Approve/Deny card " <>
        "and WAITS; only a human can approve. `target` is a project name or id.",
    busy_words: ["proposing cleanup", "awaiting approval"],
    params: [
      agent_id: {:string, required: true},
      target: {:string, required: true, description: "Project name or id to delete."},
      reason: {:string, description: "Short why — shown on the approval card."}
    ]

  alias Loopyard.Harness.Approvals

  def execute(%{agent_id: operator_id, target: target} = params, _assigns) do
    case resolve_project(target) do
      {:ok, project} ->
        action = %{
          verb: :delete_project,
          project_id: project.id,
          name: project.name,
          reason: params[:reason]
        }

        case Approvals.request(operator_id, action) do
          {:approve, msg_id} ->
            Approvals.resolve(operator_id, msg_id, %{status: :deleting})
            Loopyard.ProjectRegistry.remove_project(project.id)
            Approvals.resolve(operator_id, msg_id, %{status: :deleted})
            {:ok, "Deleted project #{project.name} and all its workspaces."}

          {:deny, _} ->
            {:ok, "The user declined to delete project #{project.name}."}

          {:timeout, _} ->
            {:ok, "No response on the delete proposal — #{project.name} was not deleted."}
        end

      {:error, msg} ->
        {:error, msg}
    end
  rescue
    e -> {:error, "Delete failed: #{inspect(e)}"}
  end

  defp resolve_project(target) do
    t = String.trim(target)
    projects = Loopyard.ProjectRegistry.list_projects()

    cond do
      p = Enum.find(projects, &(&1.id == t)) -> {:ok, p}
      p = Enum.find(projects, &(String.downcase(&1.name) == String.downcase(t))) -> {:ok, p}
      true -> {:error, "No project matched '#{target}'. Call overview to see valid names/ids."}
    end
  end
end
