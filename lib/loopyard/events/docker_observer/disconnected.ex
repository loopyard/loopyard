defmodule Loopyard.Events.DockerObserver.Disconnected do
  @moduledoc "Docker daemon stopped responding; the cache is now stale."
  defstruct []
  @type t :: %__MODULE__{}
end
