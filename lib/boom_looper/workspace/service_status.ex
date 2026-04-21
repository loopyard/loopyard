defmodule BoomLooper.Workspace.ServiceStatus do
  @moduledoc """
  Reliable service status based on docker-compose.yml + Docker state.

  This module provides service status that:
  1. Shows ALL defined services (from docker-compose.yml)
  2. Merges running state from Docker
  3. Does NOT depend on PubSub timing or ETS caching

  The docker-compose.yml is the source of truth for what services SHOULD exist.
  Docker is the source of truth for what IS running.

  ## Why a struct

  We previously returned `%{name: ..., running: true, health: :healthy}`
  and the sidebar/UI keyed off `:running` and `:health`. When those
  fields got renamed to `:status`, six tests silently broke because
  reading a missing key from a map returns `nil` and `service_dot/1`
  fell through to the gray default. Using a struct turns field renames
  into compile errors instead of silent test failures.
  """

  alias BoomLooper.Workspace
  alias BoomLooper.Compose
  alias BoomLooper.Docker
  alias BoomLooper.Workspace.ServiceStatus.Service

  @doc """
  Get complete service status for a workspace.
  Returns all defined services with their current running state.
  """
  @spec for_workspace(String.t()) :: [Service.t()]
  def for_workspace(project_dir) do
    project_dir = Path.expand(project_dir)
    workspace_id = Workspace.workspace_id(project_dir)

    # Read services from docker-compose.yml (source of truth)
    defined = list_defined_services(project_dir)

    if defined != [] do
      # Have compose file - merge with Docker running state
      running = get_all_running_states(workspace_id, defined)
      merge_status(defined, running)
    else
      # No compose file yet - check docker ps directly for running containers
      list_services_from_docker(workspace_id)
    end
  end

  @doc """
  List all services defined in docker-compose.yml.
  Returns a list of service definitions (not running state).
  """
  def list_defined_services(project_dir) do
    case File.read(Compose.compose_path(project_dir)) do
      {:ok, content} -> parse_compose_services(content)
      _ -> []
    end
  end

  # BoomLooper writes docker-compose files as JSON (Compose accepts JSON
  # because YAML is a superset). Try JSON first, fall back to a simple
  # line-based YAML parser for hand-edited files.
  defp parse_compose_services(content) do
    case Jason.decode(content) do
      {:ok, %{"services" => services}} when is_map(services) ->
        services
        |> Map.keys()
        |> Enum.reject(&(&1 == "workspace"))
        |> Enum.sort()
        |> Enum.map(fn name ->
          %Service{name: name, type: infer_service_type_from_name(name), status: :stopped}
        end)

      _ ->
        parse_compose_services_yaml(content)
    end
  end

  defp parse_compose_services_yaml(yaml_content) do
    # Simple YAML parsing for services - look for top-level service names
    # Format: "services:" followed by indented service names
    lines = String.split(yaml_content, "\n")

    {services, _} = Enum.reduce(lines, {[], false}, fn line, {acc, in_services} ->
      cond do
        String.starts_with?(line, "services:") ->
          {acc, true}

        String.starts_with?(line, "volumes:") or String.starts_with?(line, "networks:") ->
          {acc, false}

        in_services and Regex.match?(~r/^  [a-z]/, line) ->
          # Service name at 2-space indent under services:
          service_name = line |> String.trim() |> String.trim_trailing(":")
          # Skip workspace container - it's internal
          if service_name != "workspace" do
            service = %Service{
              name: service_name,
              type: infer_service_type_from_name(service_name),
              status: :stopped
            }
            {[service | acc], true}
          else
            {acc, true}
          end

        true ->
          {acc, in_services}
      end
    end)

    Enum.reverse(services)
  end

  defp infer_service_type_from_name(name) do
    cond do
      name in ["postgres", "redis", "mysql", "mongo", "minio", "rabbitmq", "memcached", "elasticsearch"] -> :stock
      true -> :process
    end
  end

  @doc """
  Get state for a specific service.
  Returns %{container: string|nil, ports: map, status: atom, exit_info: map|nil}

  Status values:
  - :running - container is running (confirmed via Docker)
  - :stopped - not running (never started or cleanly stopped)
  - :crashed - exited with non-zero code
  """
  def get_running_state(workspace_id, service_name) do
    project_name = BoomLooper.Compose.project_name(workspace_id)
    container_name = "#{project_name}-#{service_name}-1"

    cond do
      Docker.container_running?(container_name) ->
        ports = get_container_ports(container_name)
        %{
          container: container_name,
          ports: ports,
          status: :running,
          exit_info: nil
        }

      Docker.container_exists?(container_name) ->
        # Container exists but not running - check if it crashed
        exit_info = Docker.container_state(container_name)
        status = if exit_info && exit_info.exit_code > 0, do: :crashed, else: :stopped
        %{
          container: container_name,
          ports: %{},
          status: status,
          exit_info: exit_info
        }

      true ->
        # Container doesn't exist at all - it's defined in compose but never started
        %{
          container: nil,
          ports: %{},
          status: :stopped,
          exit_info: nil
        }
    end
  end

  @doc """
  Merge defined services with state from Docker.
  Default state for services we haven't checked yet is :stopped.
  """
  @spec merge_status([Service.t()], %{String.t() => map()}) :: [Service.t()]
  def merge_status(defined, running_states) do
    Enum.map(defined, fn %Service{} = service ->
      state = Map.get(running_states, service.name, %{container: nil, ports: %{}, status: :stopped, exit_info: nil})
      struct!(service, state)
    end)
  end

  # Private functions

  defp get_all_running_states(workspace_id, defined) do
    Map.new(defined, fn service ->
      {service.name, get_running_state(workspace_id, service.name)}
    end)
  end

  defp get_container_ports(container_name) do
    # Use shared Docker module function
    Docker.container_ports(container_name)
  end

  # Query docker ps directly for running containers matching this workspace
  defp list_services_from_docker(workspace_id) do
    project_name = BoomLooper.Compose.project_name(workspace_id)

    case Docker.docker([
      "ps", "--filter", "name=#{project_name}",
      "--format", "{{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}"
    ]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_docker_ps_line(&1, project_name))
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(&(&1.name == "workspace"))  # Exclude workspace container

      _ ->
        []
    end
  end

  defp parse_docker_ps_line(line, project_name) do
    case String.split(line, "\t") do
      [container_name, image, ports_str, docker_status] ->
        # Extract service name from container name (e.g., "bl-848d-postgres-1" -> "postgres")
        service_name = container_name
          |> String.replace_prefix("#{project_name}-", "")
          |> String.replace_suffix("-1", "")

        status = if String.contains?(docker_status, "Up"), do: :running, else: :stopped

        %Service{
          name: service_name,
          type: infer_service_type(image),
          image: image,
          container: container_name,
          status: status,
          ports: parse_ports(ports_str),
          exit_info: nil
        }

      _ ->
        nil
    end
  end

  defp infer_service_type(image) do
    cond do
      String.contains?(image, "postgres") -> :stock
      String.contains?(image, "redis") -> :stock
      String.contains?(image, "mysql") -> :stock
      String.contains?(image, "mongo") -> :stock
      String.contains?(image, "minio") -> :stock
      String.contains?(image, "rabbitmq") -> :stock
      true -> :process
    end
  end

  defp parse_ports(ports_str) do
    # Parse "127.0.0.1:32961->3000/tcp, ..." (or 0.0.0.0 / [::]) into
    # %{3000 => 32961}. See BoomLooper.Docker.Observer.parse_host_ports/1
    # for the same pattern — both modules parse `docker ps --format
    # {{.Ports}}` output. The hardcoded 0.0.0.0 version silently
    # returned empty maps once we bound published ports to 127.0.0.1
    # for workspace isolation.
    Regex.scan(~r/(?:\[::\]|(?:\d{1,3}\.){3}\d{1,3}):(\d+)->(\d+)/, ports_str)
    |> Map.new(fn [_, host_port, container_port] ->
      {String.to_integer(container_port), String.to_integer(host_port)}
    end)
  end
end
