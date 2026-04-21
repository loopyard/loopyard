defmodule BoomLooper.Events.IexSession do
  @moduledoc """
  Publisher module for the `"iex_session"` PubSub topic. The current
  "which IEx session is claimed and by whom" broadcast that
  `BoomLooper.IExSession` emits when claim/release changes.

  Move #2 of plans/coordination-hardening.md.
  """

  @topic "iex_session"
  @telemetry [:boom_looper, :events, :publish]

  alias BoomLooper.Events.IexSession.Changed

  @events [Changed]

  def events, do: @events
  def topic, do: @topic

  def subscribe, do: Phoenix.PubSub.subscribe(BoomLooper.PubSub, @topic)

  def publish(%Changed{} = e), do: bcast(e)

  defp bcast(%mod{} = e) do
    :telemetry.execute(@telemetry, %{count: 1}, %{topic: @topic, event: mod})
    Phoenix.PubSub.broadcast(BoomLooper.PubSub, @topic, e)
  end
end
