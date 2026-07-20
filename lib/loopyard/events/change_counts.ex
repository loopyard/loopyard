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

defmodule Loopyard.Events.ChangeCounts.Updated do
  @moduledoc "A workspace's cached changed-file count changed."
  defstruct [:workspace_id, :count]

  @type t :: %__MODULE__{workspace_id: String.t(), count: non_neg_integer()}
end

defmodule Loopyard.Events.ChangeCounts.Subscriber do
  @moduledoc """
  Behaviour for LiveViews subscribed to the change-counts topic. Implement
  `on_change_counts_updated/2` explicitly (no `@optional_callbacks`).
  """

  alias Loopyard.Events.ChangeCounts

  @type socket :: Phoenix.LiveView.Socket.t()
  @type result :: {:noreply, socket} | {:reply, map, socket}

  @callback on_change_counts_updated(ChangeCounts.Updated.t(), socket) :: result
end
