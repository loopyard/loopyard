defmodule Loopyard.Ambient.Primitive do
  @moduledoc """
  Shared synth math: sine, LFO, smoothstep, clamp, chord inversion.
  Pure functions, used by every track module.
  """

  @sample_rate 48_000

  def sample_rate, do: @sample_rate

  @doc "Sine wave at `freq` Hz evaluated at time `t` (seconds). Returns [-1, 1]."
  def sine(freq, t), do: :math.sin(2 * :math.pi * freq * t)

  @doc "LFO between `low` and `high` at `freq_hz`. Returns [low, high]."
  def lfo(t, freq_hz, low, high) do
    mid = (low + high) / 2
    amp = (high - low) / 2
    mid + amp * :math.sin(2 * :math.pi * freq_hz * t)
  end

  @doc "Smoothstep: 3x² - 2x³. Gentler than linear for crossfades."
  def smoothstep(x) when x <= 0.0, do: 0.0
  def smoothstep(x) when x >= 1.0, do: 1.0
  def smoothstep(x), do: x * x * (3.0 - 2.0 * x)

  @doc "Clamp to [-1, 1]."
  def clamp(v) when v > 1.0, do: 1.0
  def clamp(v) when v < -1.0, do: -1.0
  def clamp(v), do: v

  @doc """
  Sum of sines at the given frequencies, normalized by note count.
  Used for chord pads.
  """
  def chord_sum(notes, t) do
    Enum.reduce(notes, 0.0, fn f, acc -> acc + sine(f, t) end) / length(notes)
  end

  @doc """
  Rotate a chord N positions, raising each rotated note by an octave.
  Because additive synthesis is order-independent, a plain rotation
  would be silent — inversion has to actually shift frequencies up.
  """
  def invert_chord(notes, 0), do: notes

  def invert_chord([lowest | rest], k) when k > 0 do
    invert_chord(rest ++ [lowest * 2], k - 1)
  end
end
