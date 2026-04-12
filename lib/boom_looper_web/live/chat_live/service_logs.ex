defmodule BoomLooperWeb.Live.ChatLive.ServiceLogs do
  @moduledoc """
  Service log fetching — extracted from `BoomLooperWeb.ChatLive`.

  All functions here deal with fetching and refreshing Docker service logs.
  They are called from `handle_info` clauses in the parent LiveView.

  This file does NOT touch sockets directly for subscriptions or PubSub —
  it only reads assigns and returns updated sockets or data.
  """

  @doc """
  Fetch logs for a single container by looking up its service status entry.
  Returns a string of log output.
  """
  def fetch_service_container_logs(service_statuses, service_name) do
    case Enum.find(service_statuses, &(&1.name == service_name)) do
      nil ->
        "(container not found)"

      %{container: nil} ->
        # Service is defined in compose but no container has been started yet.
        # Don't pass nil to System.cmd — it raises ArgumentError.
        "(container not started)"

      %{container: container} = svc when is_binary(container) ->
        case BoomLooper.Docker.docker(["logs", "--tail", "200", container], timeout: 5_000) do
          {:ok, ""} ->
            if svc.status == :running, do: "(no output yet)", else: "(container exited with no output)"
          {:ok, output} -> output
          {:error, _} -> "(could not fetch logs)"
        end
    end
  catch
    :exit, _ -> "(could not fetch logs)"
  end

  @doc """
  Fetch logs for all services. Returns a list of `%{name: ..., logs: ...}` maps.
  """
  def fetch_all_service_logs(service_statuses) do
    Enum.map(service_statuses, fn svc ->
      logs =
        case svc.container do
          nil ->
            ""

          container when is_binary(container) ->
            case BoomLooper.Docker.docker(["logs", "--tail", "50", container], timeout: 5_000) do
              {:ok, output} -> output
              {:error, _} -> ""
            end
        end

      %{name: svc.name, logs: logs}
    end)
  catch
    :exit, _ -> []
  end

  @doc """
  Schedule a log refresh message to be sent after 3 seconds.
  """
  def schedule_log_refresh do
    Process.send_after(self(), :refresh_service_logs, 3_000)
  end

  @doc """
  Start an async Task that fetches service status + container logs for one
  service. Sends `:service_logs_fetched` back to the calling LiveView process.
  Returns the socket unchanged.
  """
  def start_service_logs_fetch(socket, workspace_id, service_name) do
    lv = self()

    Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn ->
      service_statuses = BoomLooper.Docker.Observer.services_for(workspace_id)
      logs = fetch_service_container_logs(service_statuses, service_name)
      send(lv, {:service_logs_fetched, service_name, service_statuses, logs})
    end)

    socket
  end

  @doc """
  Start an async Task that fetches service status + logs for all services.
  Sends `:all_service_logs_fetched` back to the calling LiveView process.
  Returns the socket unchanged.
  """
  def start_all_service_logs_fetch(socket, workspace_id) do
    lv = self()

    Task.Supervisor.start_child(BoomLooper.TaskSupervisor, fn ->
      service_statuses = BoomLooper.Docker.Observer.services_for(workspace_id)
      all_logs = fetch_all_service_logs(service_statuses)
      send(lv, {:all_service_logs_fetched, service_statuses, all_logs})
    end)

    socket
  end
end
