defmodule BoomLooper.Workspace.ServiceStatus do
  @moduledoc """
  Reliable service status based on workspace config + Docker state.

  This module provides service status that:
  1. Shows ALL defined services (from workspace config)
  2. Merges running state from Docker
  3. Does NOT depend on PubSub timing or ETS caching

  The workspace config is the source of truth for what services SHOULD exist.
  Docker is the source of truth for what IS running.
  """

  alias BoomLooper.Workspace
  alias BoomLooper.Workspace.ServiceManager
  alias BoomLooper.Docker

  @doc """
  Get complete service status for a workspace.
  Returns all defined services with their current running state.
  """
  def for_workspace(project_dir) do
    project_dir = Path.expand(project_dir)

    # First try workspace config (source of truth for what SHOULD exist)
    defined = list_defined_services(project_dir)

    if defined != [] do
      # Have config - merge with Docker running state
      workspace_id = Workspace.workspace_id(project_dir)
      running = get_all_running_states(workspace_id, defined)
      merge_status(defined, running)
    else
      # No config yet - fallback to ServiceManager (for in-progress setups)
      case ServiceManager.service_status(project_dir) do
        {:ok, statuses} -> Enum.reject(statuses, &(Map.get(&1, :type) == :workspace))
        _ -> []
      end
    end
  end

  @doc """
  List all services defined in the workspace config.
  Returns a list of service definitions (not running state).
  """
  def list_defined_services(project_dir) do
    case Workspace.load(project_dir) do
      {:ok, ws} -> extract_services(ws)
      _ -> []
    end
  end

  @doc """
  Get running state for a specific service.
  Returns %{running: bool, container: string|nil, ports: map, health: atom|nil}
  """
  def get_running_state(workspace_id, service_name) do
    container_name = ServiceManager.service_container_name(workspace_id, service_name)

    if Docker.container_running?(container_name) do
      ports = get_container_ports(container_name)
      %{
        running: true,
        container: container_name,
        ports: ports,
        health: :healthy
      }
    else
      %{
        running: false,
        container: nil,
        ports: %{},
        health: nil
      }
    end
  end

  @doc """
  Merge defined services with running state.
  """
  def merge_status(defined, running) do
    Enum.map(defined, fn service ->
      state = Map.get(running, service.name, %{running: false, container: nil, ports: %{}, health: nil})
      Map.merge(service, state)
    end)
  end

  # Private functions

  defp extract_services(ws) do
    stock_services = Enum.map(ws.services || [], fn s ->
      %{
        name: s.name,
        type: :stock,
        image: s[:image] || s["image"]
      }
    end)

    process_services = Enum.map(ws.processes || [], fn p ->
      %{
        name: p.name,
        type: :process,
        command: p[:command] || p["command"]
      }
    end)

    stock_services ++ process_services
  end

  defp get_all_running_states(workspace_id, defined) do
    Map.new(defined, fn service ->
      {service.name, get_running_state(workspace_id, service.name)}
    end)
  end

  defp get_container_ports(container_name) do
    case System.cmd("docker", ["port", container_name], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case Regex.run(~r/^(\d+)\/tcp -> [\d.:]+:(\d+)$/, line) do
            [_, container_port, host_port] ->
              Map.put(acc, container_port, host_port)
            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end
end
