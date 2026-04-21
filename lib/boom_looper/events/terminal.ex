defmodule BoomLooper.Events.Terminal do
  @moduledoc """
  Publisher module for the per-container `"terminal_output:{container}"`
  topic. Used by `BoomLooper.Terminal` to ship terminal I/O to channels
  (xterm.js) and SSH sessions.

  Move #2 of plans/coordination-hardening.md.
  """

  @telemetry [:boom_looper, :events, :publish]

  alias BoomLooper.Events.Terminal.{Output, Clear, Exit}

  @events [Output, Clear, Exit]

  def events, do: @events
  def topic(container), do: "terminal_output:#{container}"

  def subscribe(container),
    do: Phoenix.PubSub.subscribe(BoomLooper.PubSub, topic(container))

  def publish(%Output{container: c} = e) when is_binary(c), do: bcast(c, e)
  def publish(%Clear{container: c} = e) when is_binary(c), do: bcast(c, e)
  def publish(%Exit{container: c} = e) when is_binary(c), do: bcast(c, e)

  defp bcast(container, %mod{} = e) do
    t = topic(container)
    :telemetry.execute(@telemetry, %{count: 1}, %{topic: t, event: mod})
    Phoenix.PubSub.broadcast(BoomLooper.PubSub, t, e)
  end
end
