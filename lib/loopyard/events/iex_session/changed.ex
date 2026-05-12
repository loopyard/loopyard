defmodule Loopyard.Events.IexSession.Changed do
  @moduledoc "New iex-session state snapshot; `state` is the full map minus the internal `:claimed` ref."
  defstruct [:state]
end
