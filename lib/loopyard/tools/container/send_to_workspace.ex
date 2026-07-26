defmodule Loopyard.Tools.Container.SendToWorkspace do
  @moduledoc """
  Message a PEERED workspace's agent directly. Requires a human-approved
  peering grant (`propose_peering`) from THIS workspace to the target —
  refused otherwise. Delivery is the durable inbox (`enqueue_message`): the
  peer answers on its next turn, in its own chat, with provenance attached.
  """
  use Loopyard.Tool,
    name: "send_to_workspace",
    description:
      "Send a message to a PEERED workspace's agent (requires an approved " <>
        "peering — propose_peering first). The peer replies in its own chat on " <>
        "its next turn; check back with its card or ask it to send results " <>
        "back to you the same way. target = workspace name or id.",
    busy_words: ["messaging a peer workspace"],
    params: [
      agent_id: {:string, required: true},
      target: {:string, required: true, description: "Peer workspace name or id."},
      message: {:string, required: true, description: "What to tell the peer's agent."}
    ]

  alias Loopyard.{ChatAgent, Peering, ProjectRegistry, WorkspaceRegistry}

  def execute(%{agent_id: agent_id, target: target, message: message}, _assigns) do
    with %{workspace_id: my_ws} when is_binary(my_ws) <- ChatAgent.get_state(agent_id),
         {:ok, other} <- resolve(target, my_ws) do
      cond do
        not Peering.granted?(my_ws, other.id) ->
          {:error,
           "No peering grant for #{other[:name] || other.id}. Call propose_peering " <>
             "(the user must approve) — until then, coordinate via the user/operator."}

        true ->
          case first_agent(other.id) do
            nil ->
              {:error, "#{other[:name] || other.id} has no agent to receive the message."}

            peer_agent ->
              mine = WorkspaceRegistry.get_workspace(my_ws) || %{}

              ChatAgent.enqueue_message(
                peer_agent,
                "[Peer message from #{mine[:name] || my_ws} — an approved peered " <>
                  "workspace. Reply with send_to_workspace target=#{mine[:name] || my_ws}]\n\n" <>
                  message
              )

              {:ok,
               "Delivered to #{other[:name] || other.id}'s agent — it answers on its " <>
                 "next turn in its own chat. It can reply to you the same way."}
          end
      end
    else
      {:error, msg} -> {:error, msg}
      _ -> {:error, "Couldn't resolve this workspace."}
    end
  end

  defp first_agent(ws_id) do
    ChatAgent.list_agents()
    |> Enum.find(&(&1[:workspace_id] == ws_id))
    |> then(&(&1 && &1.id))
  end

  defp resolve(target, my_ws) do
    t = String.trim(target)

    all =
      for proj <- ProjectRegistry.list_projects(),
          ws <- WorkspaceRegistry.list_workspaces(proj.id),
          do: ws

    case Enum.filter(all, fn ws ->
           ws.id != my_ws and
             (ws.id == t or String.downcase(to_string(ws[:name] || "")) == String.downcase(t))
         end) do
      [ws] ->
        {:ok, ws}

      [] ->
        {:error, "No workspace matched '#{target}'."}

      many ->
        {:error,
         "Ambiguous — #{Enum.map_join(many, ", ", &"#{&1[:name]} [#{&1.id}]")}. Use the id."}
    end
  end
end
