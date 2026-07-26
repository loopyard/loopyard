defmodule Loopyard.Tools.ControlPlane.Dispatch do
  @moduledoc """
  Hand a task to a workspace's agent — the operator's "hands". Sends `message` to
  the target agent through the SAME durable inbox a human uses
  (`ChatAgent.enqueue_message/2`): it queues if the agent is busy and sends when
  it's free, so nothing is lost. The operator is the user's chief of staff, so
  dispatching to another agent is intended — the target is chosen by validated
  id/name, never trusted from a raw payload field the model could spoof for its
  own token.
  """
  use Loopyard.Tool,
    name: "dispatch",
    description:
      "Hand a task to a workspace's agent — sends `message` into that " <>
        "workspace's chat as if the user asked it there. Use after deciding a " <>
        "workspace should do something. `target` is a workspace id/name or an " <>
        "agent id. Queues if the agent is busy and sends when it's free.",
    busy_words: ["handing it off"],
    params: [
      agent_id: {:string, required: true},
      target:
        {:string,
         required: true, description: "Workspace id/name or agent id to send the task to."},
      message: {:string, required: true, description: "The task/message to send to that agent."}
    ]

  def execute(%{agent_id: operator_id, target: target, message: message}, _assigns) do
    with {:ok, agent} <- Loopyard.Tools.ControlPlane.resolve_agent(target),
         :ok <- Loopyard.ChatAgent.enqueue_message(agent.id, message) do
      # Add/refresh this workspace's job in the operator's worker queue.
      Loopyard.Operator.Jobs.note_dispatch(agent[:workspace_id], agent.id)
      # Drop a live "mini app" tile into the operator's own chat — a window INTO
      # the delegated agent (status streams working→ready; click drills into it).
      # So you watch the delegation from the cockpit instead of a peek dump.
      emit_mini_app(operator_id, agent)
      {:ok, "Dispatched to #{agent.name} (#{agent.id})#{busy_note(agent)}."}
    else
      {:error, msg} when is_binary(msg) ->
        {:error, msg}

      {:error, :unavailable} ->
        {:error, "That agent's process is down right now — try again in a moment."}
    end
  rescue
    e -> {:error, "Couldn't dispatch: #{inspect(e)}"}
  end

  defp busy_note(%{status: s}) when s in [:thinking, :backoff, :rate_limited],
    do: " — it's busy, so this queues and sends when its current turn finishes"

  defp busy_note(_), do: " — it'll pick it up now"

  # The mini-app card: a role: :embed message referencing the delegated agent.
  # `Cards.agent_embed` renders it live (reads the agent's status) and it survives
  # the :chat detail level, so the executive sees the delegation, not the plumbing.
  defp emit_mini_app(operator_id, agent) when is_binary(operator_id) do
    ws_id = agent[:workspace_id]
    ws = ws_id && Loopyard.WorkspaceRegistry.get_workspace(ws_id)

    Loopyard.ChatAgent.append_message_ets(operator_id, %{
      role: :embed,
      agent_id: agent.id,
      workspace_id: ws_id,
      project_id: ws && ws[:project_id],
      label: (ws && ws[:name]) || agent.name || "agent",
      timestamp: DateTime.utc_now()
    })

    :ok
  rescue
    _ -> :ok
  end

  defp emit_mini_app(_, _), do: :ok
end
