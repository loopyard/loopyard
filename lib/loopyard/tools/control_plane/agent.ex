defmodule Loopyard.Tools.ControlPlane.Agent do
  @moduledoc """
  The operator's agent-control tool — the "keep the fleet moving / unstick things"
  hands. One verb, an `action`, so the tool count stays lean:

    * interrupt — stop a runaway/wedged agent's current turn
    * restart   — restart a stalled agent's session (conversation kept) — the
      literal "prevent agents from being stalled" lever
    * wake      — start a stopped/asleep agent
    * new       — spawn a NEW agent in the target workspace (parallel work)

  `target` is a workspace id/name or an agent id. Guarded so the operator can't
  interrupt/restart ITSELF.
  """
  use Loopyard.Tool,
    name: "agent",
    description:
      "Control a workspace's agent to keep things moving. action=interrupt stops " <>
        "its current turn; action=restart un-sticks a wedged/stalled session " <>
        "(conversation kept); action=wake starts a stopped/asleep agent; " <>
        "action=new spawns a NEW agent in the target workspace (optional `message` " <>
        "= its first task). `target` is a workspace id/name or an agent id.",
    busy_words: ["managing an agent"],
    params: [
      agent_id: {:string, required: true},
      target: {:string, required: true, description: "Workspace id/name or agent id."},
      action: {:string, required: true, description: "interrupt | restart | wake | new"},
      message:
        {:string, description: "For action=new only: the new agent's first task (optional)."}
    ]

  alias Loopyard.{ChatAgent, Tools.ControlPlane}

  def execute(%{agent_id: operator_id, target: target} = params, _assigns) do
    case (params[:action] || "") |> to_string() |> String.downcase() do
      "new" -> spawn_new(target, params[:message])
      a when a in ["interrupt", "restart", "wake"] -> control(target, a, operator_id)
      other -> {:error, "Unknown action '#{other}'. Use interrupt, restart, wake, or new."}
    end
  rescue
    e -> {:error, "agent action failed: #{inspect(e)}"}
  end

  defp control(target, action, operator_id) do
    with {:ok, agent} <- ControlPlane.resolve_agent(target) do
      cond do
        agent.id == operator_id ->
          {:error, "That resolves to the operator itself — target a WORKSPACE agent."}

        action == "interrupt" ->
          ChatAgent.interrupt(agent.id)
          {:ok, "Interrupted #{agent.name} (#{agent.id}) — its current turn is stopping."}

        action == "restart" ->
          ChatAgent.restart_session(agent.id, :reload)
          {:ok, "Restarting #{agent.name} (#{agent.id}) — fresh session, conversation kept."}

        action == "wake" ->
          ChatAgent.start_agent(agent.id)
          {:ok, "Woke #{agent.name} (#{agent.id})."}
      end
    end
  end

  defp spawn_new(target, message) do
    with {:ok, ws_id} <- ControlPlane.resolve_workspace(target) do
      opts =
        [started_by: "operator"] ++
          if(is_binary(message) and String.trim(message) != "",
            do: [initial_message: message],
            else: []
          )

      case Loopyard.Onboarding.spawn_agent(ws_id, opts) do
        {:ok, aid} -> {:ok, "Spawned a new agent (#{aid}) in workspace #{ws_id}."}
        {:error, r} -> {:error, "Couldn't spawn an agent: #{inspect(r)}"}
      end
    end
  end
end
