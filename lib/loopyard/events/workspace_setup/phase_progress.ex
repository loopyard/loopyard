defmodule Loopyard.Events.WorkspaceSetup.PhaseProgress do
  @moduledoc """
  Mid-phase progress update — e.g. rsync byte count, git clone object count.
  `payload` is phase-specific. PR2 wires the parser; PR1 emits a generic
  status line.
  """
  defstruct [:workspace_id, :phase, :payload]
  @type t :: %__MODULE__{}
end
