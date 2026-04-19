defmodule BoomLooper.Events.DockerObserver do
  @moduledoc """
  Publisher module for the `"docker_observer"` PubSub topic.

  Move #2 of plans/coordination-hardening.md. `BoomLooper.Docker.Observer`
  broadcasts four event kinds; subscribers pattern-match on structs.
  """

  @topic "docker_observer"
  @telemetry [:boom_looper, :events, :publish]

  # Container / volume state changed (add, remove, status transition).
  defmodule Changed, do: defstruct([])

  # Full ETS wipe and rebuild. Subscribers should force-refresh.
  defmodule Reset, do: defstruct([])

  # Docker daemon stopped responding. The cache is now stale.
  defmodule Disconnected, do: defstruct([])

  # Daemon came back. Event stream re-established; cache is fresh.
  defmodule Reconnected, do: defstruct([])

  @events [Changed, Reset, Disconnected, Reconnected]

  def events, do: @events
  def topic, do: @topic

  def subscribe, do: Phoenix.PubSub.subscribe(BoomLooper.PubSub, @topic)

  def publish(%Changed{} = e), do: bcast(e)
  def publish(%Reset{} = e), do: bcast(e)
  def publish(%Disconnected{} = e), do: bcast(e)
  def publish(%Reconnected{} = e), do: bcast(e)

  defp bcast(%mod{} = e) do
    :telemetry.execute(@telemetry, %{count: 1}, %{topic: @topic, event: mod})
    Phoenix.PubSub.broadcast(BoomLooper.PubSub, @topic, e)
  end
end

defmodule BoomLooper.Events.DockerObserver.Subscriber do
  @moduledoc """
  Behaviour for LiveViews that subscribe to the `"docker_observer"` topic.
  """

  alias BoomLooper.Events.DockerObserver

  @type socket :: Phoenix.LiveView.Socket.t()
  @type result :: {:noreply, socket} | {:reply, map, socket}

  @callback on_changed(DockerObserver.Changed.t(), socket) :: result
  @callback on_reset(DockerObserver.Reset.t(), socket) :: result
  @callback on_disconnected(DockerObserver.Disconnected.t(), socket) :: result
  @callback on_reconnected(DockerObserver.Reconnected.t(), socket) :: result

  @optional_callbacks on_changed: 2,
                      on_reset: 2,
                      on_disconnected: 2,
                      on_reconnected: 2
end
