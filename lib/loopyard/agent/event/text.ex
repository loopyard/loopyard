defmodule Loopyard.Agent.Event.Text do
  @moduledoc "Complete assistant text block."
  defstruct [:text]
  @type t :: %__MODULE__{text: String.t()}
end
