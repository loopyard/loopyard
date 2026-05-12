defmodule Loopyard.Events.Terminal.Exit do
  @moduledoc "Terminal process exited for a container."
  defstruct [:container, :code]
end
