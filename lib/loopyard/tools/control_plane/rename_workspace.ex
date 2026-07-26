defmodule Loopyard.Tools.ControlPlane.RenameWorkspace do
  @moduledoc """
  The operator proposes renaming a workspace. NOT destructive, but it changes a
  shared label — so it's consent-gated (unlike the free focus descriptor, #70) so
  the operator/human always knows. Blocking approval model like the delete tools:
  post an Approve/Deny card, WAIT, apply on approve.
  """
  use Loopyard.Tool,
    name: "rename_workspace",
    description:
      "Propose renaming a workspace. Consent-gated — shows an Approve/Deny card " <>
        "and WAITS, so the human knows the label changed. `target` is a workspace " <>
        "id/name; `new_name` is the new label.",
    busy_words: ["proposing a rename"],
    params: [
      agent_id: {:string, required: true},
      target: {:string, required: true, description: "Workspace id/name to rename."},
      new_name: {:string, required: true, description: "The new name."}
    ]

  alias Loopyard.Harness.Approvals
  alias Loopyard.{WorkspaceRegistry, Tools.ControlPlane}

  def execute(%{agent_id: operator_id, target: target, new_name: new_name}, _assigns) do
    name = String.trim(to_string(new_name))

    with false <- name == "",
         {:ok, ws_id} <- ControlPlane.resolve_workspace(target),
         %{} = ws <- WorkspaceRegistry.get_workspace(ws_id) do
      action = %{
        verb: :rename_workspace,
        workspace_id: ws_id,
        old_name: ws[:name] || ws_id,
        name: name
      }

      case Approvals.request(operator_id, action) do
        {:approve, msg_id} ->
          WorkspaceRegistry.update_setup(ws_id, %{name: name})
          Approvals.resolve(operator_id, msg_id, %{status: :renamed})
          {:ok, "Renamed workspace to '#{name}'."}

        {:deny, _} ->
          {:ok, "The user declined the rename."}

        {:timeout, _} ->
          {:ok, "No response on the rename proposal — not renamed."}
      end
    else
      true ->
        {:error, "new_name can't be empty."}

      _ ->
        {:error, "Couldn't resolve workspace '#{target}'. Call overview to see valid ids/names."}
    end
  rescue
    e -> {:error, "Rename failed: #{inspect(e)}"}
  end
end
