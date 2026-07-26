defmodule Loopyard.Tools.Container.ProposePeering do
  @moduledoc """
  A workspace agent proposes PEERING with another workspace — human-approved
  access to message that workspace's agent directly (`send_to_workspace`),
  both directions. Queued approval card; only a human grants it.
  """
  use Loopyard.Tool,
    name: "propose_peering",
    description:
      "Propose direct coordination with ANOTHER workspace: on approval, your " <>
        "agents and theirs may message each other via send_to_workspace (both " <>
        "directions). Shows the user an Approve/Deny card and returns " <>
        "immediately. target = the other workspace's name or id. Say WHY in " <>
        "reason — what you two need to coordinate on.",
    busy_words: ["proposing peering", "awaiting approval"],
    params: [
      agent_id: {:string, required: true},
      target: {:string, required: true, description: "The other workspace's name or id."},
      reason: {:string, description: "What the two workspaces will coordinate on."}
    ]

  alias Loopyard.Harness.Approvals
  alias Loopyard.{ChatAgent, WorkspaceRegistry}

  def execute(%{agent_id: agent_id, target: target} = params, _assigns) do
    with %{workspace_id: my_ws} when is_binary(my_ws) <- ChatAgent.get_state(agent_id),
         {:ok, other} <- resolve(target, my_ws) do
      if Loopyard.Peering.granted?(my_ws, other.id) do
        {:ok, "Already peered with #{other[:name] || other.id} — use send_to_workspace."}
      else
        mine = WorkspaceRegistry.get_workspace(my_ws) || %{}

        Approvals.post(agent_id, %{
          verb: :peer_workspaces,
          workspace_id: my_ws,
          workspace_name: mine[:name],
          peer_workspace_id: other.id,
          peer_workspace_name: other[:name],
          reason: Map.get(params, :reason)
        })

        {:ok,
         "Proposed peering with #{other[:name] || other.id} — the user can approve " <>
           "the card whenever. Until then, coordinate through the operator. Carry on."}
      end
    else
      {:error, msg} -> {:error, msg}
      _ -> {:error, "Couldn't resolve this workspace."}
    end
  end

  defp resolve(target, my_ws) do
    t = String.trim(target)

    all =
      for proj <- Loopyard.ProjectRegistry.list_projects(),
          ws <- WorkspaceRegistry.list_workspaces(proj.id),
          do: Map.put(ws, :project_name, proj.name)

    case Enum.filter(all, fn ws ->
           ws.id != my_ws and
             (ws.id == t or String.downcase(to_string(ws[:name] || "")) == String.downcase(t))
         end) do
      [ws] ->
        {:ok, ws}

      [] ->
        {:error, "No other workspace matched '#{target}'."}

      many ->
        names = Enum.map_join(many, ", ", &"#{&1[:name]} [#{&1.id}]")
        {:error, "Ambiguous — matches: #{names}. Use the id."}
    end
  end
end
