defmodule Loopyard.Events.DockerObserver do
  @moduledoc """
  Publisher module for the `"docker_observer"` PubSub topic.

  Move #2 of plans/coordination-hardening.md. `Loopyard.Docker.Observer`
  broadcasts four event kinds; subscribers pattern-match on structs.
  """

  @topic "docker_observer"
  @telemetry [:loopyard, :events, :publish]

  alias Loopyard.Events.DockerObserver.{Changed, Reset, Disconnected, Reconnected}

  @events [Changed, Reset, Disconnected, Reconnected]

  def events, do: @events
  def topic, do: @topic

  def subscribe, do: Phoenix.PubSub.subscribe(Loopyard.PubSub, @topic)

  def publish(%Changed{} = e), do: bcast(e)
  def publish(%Reset{} = e), do: bcast(e)
  def publish(%Disconnected{} = e), do: bcast(e)
  def publish(%Reconnected{} = e), do: bcast(e)

  defp bcast(%mod{} = e) do
    :telemetry.execute(@telemetry, %{count: 1}, %{topic: @topic, event: mod})
    Phoenix.PubSub.broadcast(Loopyard.PubSub, @topic, e)
  end
end

defmodule Loopyard.Events.DockerObserver.Subscriber do
  @moduledoc """
  Behaviour for LiveViews that subscribe to the `"docker_observer"` topic.
  """

  alias Loopyard.Events.DockerObserver

  @type socket :: Phoenix.LiveView.Socket.t()
  @type result :: {:noreply, socket} | {:reply, map, socket}

  @callback on_changed(DockerObserver.Changed.t(), socket) :: result
  @callback on_reset(DockerObserver.Reset.t(), socket) :: result
  @callback on_disconnected(DockerObserver.Disconnected.t(), socket) :: result
  @callback on_reconnected(DockerObserver.Reconnected.t(), socket) :: result

  # See plans/post-migration-audit.md MEDIUM #5 — no @optional_callbacks.
end
