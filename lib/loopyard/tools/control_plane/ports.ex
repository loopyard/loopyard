defmodule Loopyard.Tools.ControlPlane.Ports do
  @moduledoc """
  See and toggle a workspace's ports from the operator. Consolidates list/open/
  close into one tool (context discipline — one verb, an `action` param). Opening
  a port flips its network exposure (loopback ↔ reachable) via
  `PortRegistry.set_exposure/4`; listing is a direct ETS read.
  """
  use Loopyard.Tool,
    name: "ports",
    description:
      "See and toggle a workspace's ports. action=list (default) shows its " <>
        "mapped ports (service, container port → host port, and whether it's " <>
        "network-exposed). action=open/close toggles NETWORK exposure of one " <>
        "port (needs service + container_port). `target` is a workspace id/name.",
    busy_words: ["working the ports"],
    params: [
      agent_id: {:string, required: true},
      target: {:string, required: true, description: "Workspace id/name."},
      action: {:string, description: "list (default), open, or close."},
      service: {:string, description: "Service name — required for open/close (see list)."},
      container_port:
        {:integer, description: "The container port — required for open/close (see list)."}
    ]

  def execute(%{target: target} = params, _assigns) do
    action = (params[:action] || "list") |> to_string() |> String.downcase()

    with {:ok, ws_id} <- Loopyard.Tools.ControlPlane.resolve_workspace(target) do
      case action do
        "list" -> {:ok, list(ws_id)}
        a when a in ["open", "close"] -> toggle(ws_id, a, params)
        _ -> {:error, "Unknown action '#{action}'. Use list, open, or close."}
      end
    end
  rescue
    e -> {:error, "Ports failed: #{inspect(e)}"}
  end

  defp list(ws_id) do
    case Loopyard.PortRegistry.list_for_workspace(ws_id) do
      [] ->
        "No ports mapped for this workspace."

      entries ->
        entries
        |> Enum.sort_by(&(&1[:container_port] || 0))
        |> Enum.map_join("\n", fn e ->
          state = if e[:exposed], do: "OPEN (network)", else: "loopback only"
          "  - #{e[:service] || "?"} #{e[:container_port] || "?"} → :#{e[:host_port]}  #{state}"
        end)
    end
  end

  defp toggle(ws_id, action, params) do
    service = params[:service]
    cport = params[:container_port]
    expose? = action == "open"

    cond do
      not is_binary(service) or service == "" ->
        {:error, "open/close needs a `service`. Run action=list to see them."}

      not is_integer(cport) ->
        {:error, "open/close needs a `container_port` (integer). Run action=list to see them."}

      true ->
        verb = if expose?, do: "Opened", else: "Closed"

        case Loopyard.PortRegistry.set_exposure(ws_id, service, cport, expose?) do
          {:error, r} -> {:error, "Couldn't #{action} the port: #{inspect(r)}"}
          _ok -> {:ok, "#{verb} #{service}:#{cport} on workspace #{ws_id}."}
        end
    end
  end
end
