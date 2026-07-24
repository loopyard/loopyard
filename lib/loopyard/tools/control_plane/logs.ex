defmodule Loopyard.Tools.ControlPlane.Logs do
  @moduledoc """
  The operator reads a workspace's service logs — the "why is this broken?"
  diagnostic (`peek` gives you the chat; this gives the actual server output).
  Works on running AND crashed containers. Read-only.
  """
  use Loopyard.Tool,
    name: "logs",
    description:
      "Read a workspace's service logs — works on running AND crashed containers. " <>
        "`target` is a workspace id/name; `service` is which service (e.g. dev, " <>
        "postgres). Omit `service` to list the workspace's containers first. Use " <>
        "it to diagnose why something's broken.",
    busy_words: ["reading logs", "log diving"],
    params: [
      agent_id: {:string, required: true},
      target: {:string, required: true, description: "Workspace id/name."},
      service:
        {:string, description: "Service name (e.g. dev, postgres). Omit to list containers."},
      lines: {:integer, description: "Trailing log lines (default 200)."}
    ]

  alias Loopyard.{Docker, Tools.ControlPlane}
  alias Loopyard.Tools.Container.Helpers

  def execute(%{target: target} = params, _assigns) do
    lines = params[:lines] || 200

    with {:ok, ws_id} <- ControlPlane.resolve_workspace(target) do
      case params[:service] do
        s when is_binary(s) and s != "" -> logs(ws_id, s, lines)
        _ -> list_containers(ws_id)
      end
    end
  rescue
    e -> {:error, "logs failed: #{inspect(e)}"}
  end

  defp logs(ws_id, service, lines) do
    container = Loopyard.Workspace.ServiceManager.service_container_name(ws_id, service)

    case Docker.container_logs(container, tail: lines) do
      {:ok, output} -> {:ok, Helpers.truncate_for_agent(output)}
      {:error, reason} -> {:error, "Couldn't read #{service} logs: #{inspect(reason)}"}
    end
  end

  defp list_containers(ws_id) do
    case Docker.Observer.containers_for(ws_id) do
      [] ->
        {:ok, "No containers for this workspace. Bring it up with workspace(target, up)."}

      cs ->
        rows =
          Enum.map_join(cs, "\n", fn c ->
            "  - #{c[:service] || c[:name]} (#{if c[:running], do: "running", else: "stopped"})"
          end)

        {:ok, "Services here (pass one as `service`):\n#{rows}"}
    end
  end
end
