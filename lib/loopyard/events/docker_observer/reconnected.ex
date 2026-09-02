defmodule Loopyard.Events.DockerObserver.Reconnected do
  @moduledoc "Daemon came back; event stream re-established and cache is fresh."
  defstruct []
  @type t :: %__MODULE__{}
end
