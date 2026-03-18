defmodule Hive.Workspace.ServiceManager do
  @moduledoc """
  GenServer managing service containers (databases, caches, etc.) for a workspace.
  One ServiceManager per unique workspace path. All agents at the same path share services.

  Service containers are named: hive-svc-{workspace_id}-{service_name}
  Data volumes persist: hive-svc-{workspace_id}-{service_name}-data
  """
  use GenServer, restart: :transient

  alias Hive.Docker

  @prefix "hive-svc"

  defstruct [:project_dir, :workspace_id, services: %{}]

  # --- Public API ---

  def start_link(opts) do
    project_dir = Keyword.fetch!(opts, :project_dir)
    GenServer.start_link(__MODULE__, opts, name: via(project_dir))
  end

  @doc "Start all services defined in the workspace config"
  def start_services(project_dir) do
    case find_or_start(project_dir) do
      {:ok, pid} -> GenServer.call(pid, :start_services, 120_000)
      error -> error
    end
  end

  @doc "Stop all service containers for a workspace"
  def stop_services(project_dir) do
    case Registry.lookup(Hive.ServiceManagerRegistry, project_dir) do
      [{pid, _}] -> GenServer.call(pid, :stop_services, 30_000)
      [] -> :ok
    end
  end

  @doc "Get status of all services for a workspace"
  def service_status(project_dir) do
    case Registry.lookup(Hive.ServiceManagerRegistry, project_dir) do
      [{pid, _}] -> GenServer.call(pid, :service_status)
      [] -> {:ok, []}
    end
  end

  @doc "Container name for a workspace service"
  def service_container_name(workspace_id, service_name) do
    "#{@prefix}-#{workspace_id}-#{service_name}"
  end

  @doc "Data volume name for a workspace service"
  def service_volume_name(workspace_id, service_name) do
    "#{@prefix}-#{workspace_id}-#{service_name}-data"
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    project_dir = Keyword.fetch!(opts, :project_dir)
    workspace_id = Hive.Workspace.workspace_id(project_dir)
    {:ok, %__MODULE__{project_dir: project_dir, workspace_id: workspace_id}}
  end

  @impl true
  def handle_call(:start_services, _from, state) do
    case Hive.Workspace.load(state.project_dir) do
      {:ok, workspace} ->
        results = Enum.map(workspace.services, &start_service_container(state.workspace_id, &1))
        services = Map.new(workspace.services, fn s -> {s.name, s} end)
        {:reply, {:ok, results}, %{state | services: services}}

      :none ->
        {:reply, {:ok, []}, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call(:stop_services, _from, state) do
    Enum.each(state.services, fn {name, _} ->
      Docker.docker(["rm", "-f", service_container_name(state.workspace_id, name)])
    end)

    {:reply, :ok, %{state | services: %{}}}
  end

  @impl true
  def handle_call(:service_status, _from, state) do
    statuses =
      Enum.map(state.services, fn {name, service} ->
        container = service_container_name(state.workspace_id, name)

        %{
          name: name,
          image: service.image,
          running: container_running?(container),
          container: container
        }
      end)

    {:reply, {:ok, statuses}, state}
  end

  # --- Private ---

  defp find_or_start(project_dir) do
    case Registry.lookup(Hive.ServiceManagerRegistry, project_dir) do
      [{pid, _}] -> {:ok, pid}
      [] -> DynamicSupervisor.start_child(Hive.ServiceManagerSupervisor, {__MODULE__, project_dir: project_dir})
    end
  end

  defp start_service_container(workspace_id, service) do
    container = service_container_name(workspace_id, service.name)

    if container_running?(container) do
      {:ok, :already_running}
    else
      Docker.docker(["rm", "-f", container])
      Docker.ensure_network()

      vol_name = service_volume_name(workspace_id, service.name)
      Docker.docker(["volume", "create", vol_name])

      env_args = Enum.flat_map(service.env || %{}, fn {k, v} -> ["-e", "#{k}=#{v}"] end)
      port_args = Enum.flat_map(service.ports || %{}, fn {host, cp} -> ["-p", "#{host}:#{cp}"] end)
      volume_args = Enum.flat_map(service.volumes || [], fn spec -> ["-v", "#{spec}"] end)

      args =
        ["run", "-d", "--name", container, "--network", Docker.network_name()] ++
          env_args ++ port_args ++ volume_args ++ [service.image]

      case Docker.docker(args, timeout: 120_000) do
        {:ok, _} -> {:ok, :started}
        {:error, reason} -> {:error, "Failed to start #{service.name}: #{reason}"}
      end
    end
  end

  defp container_running?(container_name) do
    case Docker.docker(["inspect", "-f", "{{.State.Running}}", container_name]) do
      {:ok, output} -> String.trim(output) == "true"
      _ -> false
    end
  end

  defp via(project_dir) do
    {:via, Registry, {Hive.ServiceManagerRegistry, project_dir}}
  end
end
