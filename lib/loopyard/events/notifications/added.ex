defmodule Loopyard.Events.Notifications.Added do
  @moduledoc "A notification was raised (`item` is a `Loopyard.Notifications.Item`)."
  defstruct [:item]
end
