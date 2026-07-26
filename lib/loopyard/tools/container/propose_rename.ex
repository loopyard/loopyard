defmodule Loopyard.Tools.Container.ProposeRename do
  @moduledoc """
  A workspace agent proposes renaming its own PROJECT or WORKSPACE. Queued
  approval (card in the chat + the attention line; no TTL) — only a human can
  approve, so an agent may suggest better names but never relabel anything on
  its own. Applied by `Approvals.run/3` on approve.
  """
  use Loopyard.Tool,
    name: "propose_rename",
    description:
      "Propose renaming this workspace's PROJECT or this WORKSPACE (branch " <>
        "label). Shows the user an Approve/Deny card and returns immediately — " <>
        "a human decides whenever. Use when the current name is unclear, stale, " <>
        "or wrong (say why in reason).",
    busy_words: ["proposing a rename", "awaiting approval"],
    params: [
      agent_id: {:string, required: true},
      scope:
        {:string,
         required: true,
         description: "What to rename: \"project\" or \"workspace\"."},
      new_name: {:string, required: true, description: "The proposed new name."},
      reason: {:string, description: "Short why — shown on the approval card."}
    ]

  alias Loopyard.Harness.Approvals
  alias Loopyard.{ChatAgent, ProjectRegistry, WorkspaceRegistry}

  def execute(%{agent_id: agent_id, scope: scope, new_name: new_name} = params, _assigns) do
    name = String.trim(to_string(new_name))

    with false <- name == "",
         %{workspace_id: ws_id} when is_binary(ws_id) <- ChatAgent.get_state(agent_id),
         %{} = ws <- WorkspaceRegistry.get_workspace(ws_id) do
      case String.downcase(String.trim(scope)) do
        "project" ->
          project = ProjectRegistry.get_project(ws[:project_id])

          Approvals.post(agent_id, %{
            verb: :rename_project,
            project_id: ws[:project_id],
            old_name: (project && project.name) || ws[:project_id],
            name: name,
            reason: Map.get(params, :reason)
          })

          {:ok,
           "Proposed renaming the project to '#{name}' — the user can approve the " <>
             "card whenever. Carry on; don't wait for it."}

        "workspace" ->
          Approvals.post(agent_id, %{
            verb: :rename_workspace,
            workspace_id: ws_id,
            old_name: ws[:name] || ws_id,
            name: name,
            reason: Map.get(params, :reason)
          })

          {:ok,
           "Proposed renaming this workspace to '#{name}' — the user can approve " <>
             "the card whenever. Carry on; don't wait for it."}

        other ->
          {:error, "scope must be \"project\" or \"workspace\" (got #{inspect(other)})."}
      end
    else
      true -> {:error, "new_name can't be empty."}
      _ -> {:error, "Couldn't resolve this workspace."}
    end
  rescue
    e -> {:error, "Couldn't propose the rename: #{inspect(e)}"}
  end
end
