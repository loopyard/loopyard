defmodule Loopyard.Events.Terminal.Output do
  @moduledoc "Terminal stdout/stderr payload for a container."
  defstruct [:container, :data]
end
