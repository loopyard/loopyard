defmodule Loopyard.Events.Notifications.Changed do
  @moduledoc """
  A notification changed state — settled, dismissed, retracted, re-prioritised.
  `item` is the new `Loopyard.Notifications.Item`; `from` the previous status.
  """
  defstruct [:item, :from]
end
