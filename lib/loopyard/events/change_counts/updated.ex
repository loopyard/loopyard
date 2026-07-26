defmodule Loopyard.Events.ChangeCounts.Updated do
  @moduledoc "A workspace's cached changed-file count changed."
  defstruct [:workspace_id, :count]

  @type t :: %__MODULE__{workspace_id: String.t(), count: non_neg_integer()}
end
