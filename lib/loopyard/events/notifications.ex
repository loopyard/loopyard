defmodule Loopyard.Events.Notifications do
  @moduledoc """
  Publisher module for the `"notifications"` PubSub topic — the inbox's
  changes: an item raised, an item settled / dismissed / retracted.

  Every broadcast on this topic goes through here (the pubsub boundary test
  enforces it). Subscribers: the notifications deck, the dashboard, the app
  badge, push, chimes — anything that used to poll `Attention.line/0`.
  """

  @topic "notifications"
  @telemetry [:loopyard, :events, :publish]

  alias Loopyard.Events.Notifications.{Added, Changed}

  @events [Added, Changed]

  @doc "List of every event module published on this topic."
  def events, do: @events

  @doc "Topic name for this publisher."
  def topic, do: @topic

  @doc "Subscribe the current process to inbox changes."
  def subscribe, do: Phoenix.PubSub.subscribe(Loopyard.PubSub, @topic)

  @doc "Broadcast an inbox event. Any other shape raises at the call site."
  def publish(%Added{} = e), do: bcast(e)
  def publish(%Changed{} = e), do: bcast(e)

  defp bcast(%mod{} = e) do
    :telemetry.execute(@telemetry, %{count: 1}, %{topic: @topic, event: mod})
    Phoenix.PubSub.broadcast(Loopyard.PubSub, @topic, e)
  end
end
