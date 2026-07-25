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
          # Real blast radius, so the card can tell the truth: an EMPTY project
          # (0 workspaces) has nothing to tear down, and shouldn't wear the scary
          # "destroys ALL its workspaces, irreversible" boilerplate.
          workspace_count: length(Loopyard.WorkspaceRegistry.list_workspaces(project.id)),
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

    # An exact id is unambiguous — take it.
    case Enum.find(projects, &(&1.id == t)) do
      %{} = p ->
        {:ok, p}

      nil ->
        # By NAME: a destructive, cascading delete must NEVER guess. If a name
        # matches more than one project (a real one plus empty duplicates), do
        # NOT silently pick the first — you could nuke the project that holds all
        # the work. Refuse and show which is which (id + workspace count) so the
        # caller targets the exact id. This is the safety boundary: ambiguity is
        # an error, not a coin flip.
        case Enum.filter(projects, &(String.downcase(&1.name) == String.downcase(t))) do
          [p] ->
            {:ok, p}

          [] ->
            {:error, "No project matched '#{target}'. Call overview to see valid names/ids."}

          many ->
            candidates =
              Enum.map_join(many, "; ", fn p ->
                n = length(Loopyard.WorkspaceRegistry.list_workspaces(p.id))
                "#{p.id} (#{n} workspace#{if n == 1, do: "", else: "s"})"
              end)

            {:error,
             "Ambiguous — #{length(many)} projects are named '#{target}', so I won't guess which to delete " <>
               "(one likely holds all the work). Pass the exact project id. Candidates: #{candidates}."}
        end
    end
  end
end
