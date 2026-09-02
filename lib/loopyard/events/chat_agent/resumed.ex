defmodule Loopyard.Events.ChatAgent.Resumed do
  @moduledoc "Agent GenServer restored from the log — same ID, fresh Claude session."
  defstruct [:summary]
  @type t :: %__MODULE__{}
end
