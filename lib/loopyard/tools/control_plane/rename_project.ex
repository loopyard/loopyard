defmodule Loopyard.Tools.ControlPlane.RenameProject do
  @moduledoc """
  The operator proposes renaming a project. Consent-gated (blocking approval
  model) so the human knows the label changed. Applies via
  `ProjectRegistry.rename_project/2` (ETS + disk persistence, unique-name safe).
  """
  use Loopyard.Tool,
    name: "rename_project",
    description:
      "Propose renaming a project. Consent-gated — shows an Approve/Deny card and " <>
        "WAITS, so the human knows the label changed. `target` is a project name " <>
        "or id; `new_name` is the new name.",
    busy_words: ["proposing a rename"],
    params: [
      agent_id: {:string, required: true},
      target: {:string, required: true, description: "Project name or id to rename."},
      new_name: {:string, required: true, description: "The new name."}
    ]

  alias Loopyard.Harness.Approvals

  def execute(%{agent_id: operator_id, target: target, new_name: new_name}, _assigns) do
    name = String.trim(to_string(new_name))

    with false <- name == "",
         {:ok, project} <- resolve_project(target) do
      action = %{
        verb: :rename_project,
        project_id: project.id,
        old_name: project.name,
        name: name
      }

      case Approvals.request(operator_id, action) do
        {:approve, msg_id} ->
          case Loopyard.ProjectRegistry.rename_project(project.id, name) do
            {:ok, updated} ->
              Approvals.resolve(operator_id, msg_id, %{status: :renamed})
              {:ok, "Renamed project to '#{updated.name}'."}

            {:error, reason} ->
              Approvals.resolve(operator_id, msg_id, %{status: :failed, error: inspect(reason)})
              {:error, "Couldn't rename the project: #{inspect(reason)}"}
          end

        {:deny, _} ->
          {:ok, "The user declined the rename."}

        {:timeout, _} ->
          {:ok, "No response on the rename proposal — not renamed."}
      end
    else
      true -> {:error, "new_name can't be empty."}
      {:error, msg} -> {:error, msg}
    end
  rescue
    e -> {:error, "Rename failed: #{inspect(e)}"}
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
