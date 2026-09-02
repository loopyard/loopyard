defmodule Loopyard.Events.IexSession do
  @moduledoc """
  Publisher module for the `"iex_session"` PubSub topic. The current
  "which IEx session is claimed and by whom" broadcast that
  `Loopyard.IExSession` emits when claim/release changes.

  Move #2 of plans/archive/coordination-hardening.md.
  """

  @topic "iex_session"
  @telemetry [:loopyard, :events, :publish]

  alias Loopyard.Events.IexSession.Changed

  @events [Changed]

  def events, do: @events
  def topic, do: @topic

  def subscribe, do: Phoenix.PubSub.subscribe(Loopyard.PubSub, @topic)

  def publish(%Changed{} = e), do: bcast(e)

  defp bcast(%mod{} = e) do
    :telemetry.execute(@telemetry, %{count: 1}, %{topic: @topic, event: mod})
    Phoenix.PubSub.broadcast(Loopyard.PubSub, @topic, e)
  end
end
