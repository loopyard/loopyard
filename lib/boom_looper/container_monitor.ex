defmodule BoomLooper.ContainerMonitor do
  @moduledoc """
  Polls Docker container health for a branch and broadcasts status changes.
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

  def handle_info(_, state), do: {:noreply, state}

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  defp broadcast_status(project_dir) do
    case Registry.lookup(BoomLooper.ServiceManagerRegistry, project_dir) do
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
