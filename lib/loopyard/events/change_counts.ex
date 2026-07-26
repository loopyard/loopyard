defmodule Loopyard.Events.ChangeCounts do
  @moduledoc """
  Publisher for the global `"change_counts"` PubSub topic — a workspace's
  cached changed-file count moved (see `Loopyard.ChangeCounts`). Overview
  surfaces (the god-mode rail, /workspaces, home) subscribe and refresh their
  tree so the ±N badge is live without any render-time git work.

  Per the PubSub boundary rule this is the ONLY place these broadcasts happen;
  every subscriber implements the `Subscriber` behaviour with an explicit
  callback (no `@optional_callbacks`).
  """
  @telemetry [:loopyard, :events, :publish]
  @topic "change_counts"

  alias Loopyard.Events.ChangeCounts.Updated

  @events [Updated]

  def events, do: @events

  def topic, do: @topic

  def subscribe, do: Phoenix.PubSub.subscribe(Loopyard.PubSub, @topic)

  def publish(%Updated{workspace_id: ws} = e) when is_binary(ws) do
    :telemetry.execute(@telemetry, %{count: 1}, %{topic: @topic, event: Updated})
    Phoenix.PubSub.broadcast(Loopyard.PubSub, @topic, e)
  end

  def publish(%Updated{}), do: :ok
end
