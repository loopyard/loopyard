defmodule Loopyard.Events.SourceSync do
  @moduledoc """
  Publisher module for the per-workspace `"source_sync:{workspace_id}"`
  PubSub topic. `Loopyard.Source.Local.SyncMonitor` publishes here when
  the mutagen sync session status changes.

  Move #2 of plans/coordination-hardening.md.
  """

  @telemetry [:loopyard, :events, :publish]

  alias Loopyard.Events.SourceSync.Updated

  @events [Updated]

  def events, do: @events
  def topic(workspace_id), do: "source_sync:#{workspace_id}"

  def subscribe(workspace_id),
    do: Phoenix.PubSub.subscribe(Loopyard.PubSub, topic(workspace_id))

  def publish(%Updated{workspace_id: id} = e) when is_binary(id), do: bcast(id, e)

  defp bcast(workspace_id, %mod{} = e) do
    t = topic(workspace_id)
    :telemetry.execute(@telemetry, %{count: 1}, %{topic: t, event: mod})
    Phoenix.PubSub.broadcast(Loopyard.PubSub, t, e)
  end
end

defmodule Loopyard.Events.SourceSync.Subscriber do
  @moduledoc """
  Behaviour for LiveViews that subscribe to a workspace's sync topic.
  """

  alias Loopyard.Events.SourceSync

  @type socket :: Phoenix.LiveView.Socket.t()
  @type result :: {:noreply, socket} | {:reply, map, socket}

  @callback on_updated(SourceSync.Updated.t(), socket) :: result

  # No @optional_callbacks — the point of Move #3 is compile-time
  # enforcement. Explicit opt-out is `def on_updated(_, s), do: {:noreply, s}`.
end
