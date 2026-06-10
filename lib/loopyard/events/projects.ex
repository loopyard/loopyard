defmodule Loopyard.Events.Projects do
  @moduledoc """
  Publisher for the GLOBAL `"projects"` PubSub topic — the project list changed
  (a project was created or removed). The home (project list) LiveView
  subscribes so every viewer's list updates in real time. Multiplayer: a project
  someone else creates appears in your list without a refresh.

  Per the PubSub boundary rule, this is the ONLY place `projects` broadcasts.
  """
  @telemetry [:loopyard, :events, :publish]

  alias Loopyard.Events.Projects.Changed

  @events [Changed]

  def events, do: @events
  def topic, do: "projects"

  def subscribe, do: Phoenix.PubSub.subscribe(Loopyard.PubSub, topic())

  def publish(%Changed{} = e), do: bcast(e)

  defp bcast(%mod{} = e) do
    t = topic()
    :telemetry.execute(@telemetry, %{count: 1}, %{topic: t, event: mod})
    Phoenix.PubSub.broadcast(Loopyard.PubSub, t, e)
  end
end

defmodule Loopyard.Events.Projects.Subscriber do
  @moduledoc """
  Behaviour for LiveViews that subscribe to the global projects topic.
  Implement `on_changed/2` explicitly (no `@optional_callbacks`).
  """

  alias Loopyard.Events.Projects

  @type socket :: Phoenix.LiveView.Socket.t()
  @type result :: {:noreply, socket} | {:reply, map, socket}

  @callback on_changed(Projects.Changed.t(), socket) :: result
end
