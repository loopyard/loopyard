defmodule BoomLooper.Events.ChatAgent.BootFailed do
  @moduledoc "Boot definitively failed; the stub has been removed from ETS."
  defstruct [:id, :reason]
end
