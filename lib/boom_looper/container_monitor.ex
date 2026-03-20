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
    {:ok, %{project_dir: project_dir, last_statuses: %{}}}
  end

  @impl true
  def handle_info(:poll, state) do
    check_containers(state)
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  defp check_containers(state) do
    # Trigger a service status broadcast which will pick up
    # any container state changes (including deaths)
    case Registry.lookup(BoomLooper.ServiceManagerRegistry, state.project_dir) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, :service_status, 5_000)
        catch
          :exit, _ -> :ok
        end
        # Re-broadcast so the UI updates
        try do
          GenServer.cast(pid, :broadcast_status)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end
  end
end
