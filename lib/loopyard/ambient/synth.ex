defmodule Loopyard.Ambient.Synth do
  @moduledoc """
  Pure-functions ambient synth. Generates 16-bit signed PCM samples
  from a sample index — no state, no GenServer, no PubSub.

  Used by the HTTP streaming controller
  (`LoopyardWeb.AmbientStreamController`) and the standalone WAV
  script (`scripts/ambient_wav.exs`).

  Each listener has their own integer sample counter `t`. Render the
  next chunk with `render_chunk(t, n_samples)`, advance `t` by
  `n_samples`, repeat. The synth itself never tracks anything across
  calls.

  See `plans/ambient-soundtrack.md` for the design rationale.
  """

  @sample_rate 48_000
  @chord_samples 12 * @sample_rate
  @cycle_samples 4 * @chord_samples

  @chords [
    {[261.63, 329.63, 392.00, 493.88], 65.41},
    {[220.00, 261.63, 329.63, 392.00], 55.00},
    {[174.61, 220.00, 261.63, 329.63], 87.31},
    {[196.00, 246.94, 293.66, 369.99], 49.00}
  ]

  @doc "Sample rate the synth generates at."
  def sample_rate, do: @sample_rate

  @doc """
  Render `n_samples` of audio starting at sample index `start_t`.
  Returns a binary of little-endian signed 16-bit PCM (mono).
  """
  def render_chunk(start_t, n_samples) when is_integer(start_t) and is_integer(n_samples) do
    for i <- 0..(n_samples - 1), into: <<>> do
      sample = sample_at(start_t + i) |> clamp()
      <<round(sample * 32_767)::little-signed-16>>
    end
  end

  # Sample value at integer index `n`. Wraps the cycle so chord
  # progression loops forever.
  defp sample_at(n) do
    n_mod = rem(n, @cycle_samples)
    t = n_mod / @sample_rate

    chord_index = div(n_mod, @chord_samples)
    chord_progress = rem(n_mod, @chord_samples) / @chord_samples

    {notes_a, bass_a} = Enum.at(@chords, chord_index)
    {notes_b, bass_b} = Enum.at(@chords, rem(chord_index + 1, length(@chords)))

    alpha = smoothstep(max(0.0, (chord_progress - 0.5) * 2.0))

    pad = (1.0 - alpha) * chord_sum(notes_a, t) + alpha * chord_sum(notes_b, t)
    bass = (1.0 - alpha) * sine(bass_a, t) + alpha * sine(bass_b, t)

    pad_gain = 0.30 * lfo(t, 0.07, 0.85, 1.0)
    bass_gain = 0.18

    pad_gain * pad + bass_gain * bass
  end

  defp chord_sum(notes, t) do
    Enum.reduce(notes, 0.0, fn f, acc -> acc + sine(f, t) end) / length(notes)
  end

  defp sine(freq, t), do: :math.sin(2 * :math.pi * freq * t)

  defp lfo(t, freq_hz, low, high) do
    mid = (low + high) / 2
    amp = (high - low) / 2
    mid + amp * :math.sin(2 * :math.pi * freq_hz * t)
  end

  defp smoothstep(x) when x <= 0.0, do: 0.0
  defp smoothstep(x) when x >= 1.0, do: 1.0
  defp smoothstep(x), do: x * x * (3.0 - 2.0 * x)

  defp clamp(v) when v > 1.0, do: 1.0
  defp clamp(v) when v < -1.0, do: -1.0
  defp clamp(v), do: v
end
