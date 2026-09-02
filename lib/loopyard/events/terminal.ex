defmodule Loopyard.Events.Terminal do
  @moduledoc """
  Publisher module for the per-container `"terminal_output:{container}"`
  topic. Used by `Loopyard.Terminal` to ship terminal I/O to channels
  (xterm.js) and SSH sessions.

  Move #2 of plans/archive/coordination-hardening.md.
  """

  @telemetry [:loopyard, :events, :publish]

  alias Loopyard.Events.Terminal.{Output, Clear, Exit}

  @events [Output, Clear, Exit]

  def events, do: @events
  def topic(container), do: "terminal_output:#{container}"

  def subscribe(container),
    do: Phoenix.PubSub.subscribe(Loopyard.PubSub, topic(container))

  def publish(%Output{container: c} = e) when is_binary(c), do: bcast(c, e)
  def publish(%Clear{container: c} = e) when is_binary(c), do: bcast(c, e)
  def publish(%Exit{container: c} = e) when is_binary(c), do: bcast(c, e)

  defp bcast(container, %mod{} = e) do
    t = topic(container)
    :telemetry.execute(@telemetry, %{count: 1}, %{topic: t, event: mod})
    Phoenix.PubSub.broadcast(Loopyard.PubSub, t, e)
  end
end
