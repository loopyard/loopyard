defmodule Loopyard.Tools.ControlPlane.NotifyWhenDone do
  @moduledoc """
  "Tell me when it's done." Arm a watch on a workspace agent the operator
  dispatched to; when that agent next finishes its turn (or stalls), Loopyard
  wakes the operator to report — no polling, no guessing.

  The trigger lives in Loopyard (`Operator.Digest`, riding the turn-end idle
  event), NOT in the watched agent's harness — so a sub-agent that crashes or
  forgets can't swallow the notification. The result itself sits durably in the
  `Operator.Jobs` slot (pull-safe), so even a missed wake never loses the answer.

  Refuses to arm on an agent that's already idle — there's nothing running to
  wait for, so dispatch it first.
  """
  use Loopyard.Tool,
    name: "notify_when_done",
    description:
      "Get told when a dispatched task finishes. `target` is a workspace " <>
        "id/name or agent id you handed work to. When that agent next finishes " <>
        "its turn (or stalls), you're woken to report the result to the user — " <>
        "use this instead of promising to 'check back'. Only works on a busy " <>
        "agent (dispatch first).",
    busy_words: ["setting a watch"],
    params: [
      agent_id: {:string, required: true},
      target:
        {:string,
         required: true,
         description: "Workspace id/name or agent id whose completion to watch."}
    ]

  alias Loopyard.Tools.ControlPlane

  def execute(%{agent_id: operator_id, target: target}, _assigns) do
    with {:ok, agent} <- ControlPlane.resolve_agent(target),
         {:ok, ws_id} <- workspace_id(agent),
         :ok <- ensure_busy(agent) do
      name = workspace_name(ws_id, agent)
      Loopyard.Operator.Digest.watch(ws_id, agent.id, operator_id, name)

      {:ok,
       "Watching #{name} — I'll report the moment it finishes (or if it stalls). " <>
         "You don't have to check back."}
    end
  rescue
    e -> {:error, "Couldn't set the watch: #{inspect(e)}"}
  end

  defp workspace_id(%{workspace_id: ws}) when is_binary(ws), do: {:ok, ws}

  defp workspace_id(_),
    do: {:error, "That target has no workspace — only workspace agents can be watched."}

  # Nothing to wait for if it's not currently working. Better to say so than arm a
  # watch that only resolves on the (long) stall TTL.
  defp ensure_busy(%{status: s}) when s in [:thinking, :backoff, :rate_limited], do: :ok

  defp ensure_busy(_),
    do:
      {:error,
       "That agent is idle right now — there's nothing running to wait for. " <>
         "Dispatch it a task first, then arm the watch."}

  defp workspace_name(ws_id, agent) do
    case ControlPlane.resolve_workspace(ws_id) do
      {:ok, %{name: name}} when is_binary(name) and name != "" -> name
      _ -> agent.name || ws_id
    end
  end
end
