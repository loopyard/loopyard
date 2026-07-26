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
