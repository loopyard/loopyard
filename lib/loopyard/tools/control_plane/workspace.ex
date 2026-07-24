defmodule Loopyard.Tools.ControlPlane.Workspace do
  @moduledoc """
  The operator's workspace dev-cluster control — boot a workspace to work on it,
  or shut it down to reclaim memory. One verb, an `action`:

    * up      — boot its services (dev server, postgres, …), best-effort/async
    * down    — shut them down (frees RAM)
    * restart — down, then back up

  `target` is a workspace id/name. Read ports/status with `overview`.
  """
  use Loopyard.Tool,
    name: "workspace",
    description:
      "Control a workspace's dev cluster. action=up boots its services (dev " <>
        "server, postgres, …); action=down shuts them down (frees memory); " <>
        "action=restart bounces them. `target` is a workspace id/name. See its " <>
        "ports/status with overview.",
    busy_words: ["managing a workspace"],
    params: [
      agent_id: {:string, required: true},
      target: {:string, required: true, description: "Workspace id/name."},
      action: {:string, required: true, description: "up | down | restart"}
    ]

  alias Loopyard.Tools.ControlPlane

  def execute(%{target: target} = params, _assigns) do
    action = (params[:action] || "") |> to_string() |> String.downcase()

    with {:ok, ws_id} <- ControlPlane.resolve_workspace(target) do
      case action do
        "up" ->
          Loopyard.Onboarding.start_preview_async(ws_id)
          {:ok, "Bringing workspace #{ws_id}'s dev cluster up (background) — check overview for ports when ready."}

        "down" ->
          Loopyard.Workspace.ServiceManager.stop_services(Loopyard.Workspace.compose_dir(ws_id))
          {:ok, "Shut down workspace #{ws_id}'s dev cluster."}

        "restart" ->
          Loopyard.Workspace.ServiceManager.stop_services(Loopyard.Workspace.compose_dir(ws_id))
          Loopyard.Onboarding.start_preview_async(ws_id)
          {:ok, "Restarting workspace #{ws_id}'s dev cluster (down, then back up in the background)."}

        other ->
          {:error, "Unknown action '#{other}'. Use up, down, or restart."}
      end
    end
  rescue
    e -> {:error, "workspace action failed: #{inspect(e)}"}
  end
end
