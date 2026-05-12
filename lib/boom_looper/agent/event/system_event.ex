defmodule BoomLooper.Agent.Event.SystemEvent do
  @moduledoc "SDK system message (init, compaction, hooks, etc.)."
  defstruct [:subtype, :content]
  @type t :: %__MODULE__{subtype: atom(), content: String.t() | nil}
end
