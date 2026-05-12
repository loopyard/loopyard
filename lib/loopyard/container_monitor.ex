defmodule Loopyard.ContainerMonitor do
  @moduledoc """
  Polls Docker container health for a workspace and broadcasts status changes.
  Detects when containers die and updates the UI with exit info.
  """
  use GenServer

  @poll_interval 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    project_dir = Keyword.fetch!(opts, :project_dir)
    schedule_poll()
    {:ok, %{project_dir: project_dir}}
  end

  @impl true
  def handle_info(:poll, state) do
    broadcast_status(state.project_dir)
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    require Logger
    Logger.warning("[ContainerMonitor] unhandled: #{inspect(msg, limit: 200)}")

    :telemetry.execute(
      [:loopyard, :actor, :unknown_message],
      %{count: 1},
      %{actor: __MODULE__, msg: inspect(msg, limit: 200)}
    )

    {:noreply, state}
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  defp broadcast_status(project_dir) do
    case Registry.lookup(Loopyard.ServiceManagerRegistry, project_dir) do
      [{pid, _}] ->
        try do
          GenServer.cast(pid, :check_health)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end
  end
end
