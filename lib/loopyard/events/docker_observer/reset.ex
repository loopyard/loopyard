defmodule Loopyard.Events.DockerObserver.Reset do
  @moduledoc "Full ETS wipe and rebuild; subscribers should force-refresh."
  defstruct []
  @type t :: %__MODULE__{}
end
