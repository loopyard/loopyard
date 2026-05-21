defmodule Loopyard.Ambient.Track do
  @moduledoc """
  Behaviour for ambient tracks. Each track is a pure function from
  integer sample index → float sample in [-1, 1]. The Synth
  dispatcher renders chunks by calling `sample_at/1` for each
  sample index.
  """

  @callback sample_at(n :: integer) :: float
end
