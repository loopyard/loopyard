defmodule BoomLooper.Agent.Event.TextDelta do
  @moduledoc "Streaming text fragment (partial response)."
  defstruct [:text]
  @type t :: %__MODULE__{text: String.t()}
end
