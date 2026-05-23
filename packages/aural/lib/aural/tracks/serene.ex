defmodule Aural.Tracks.Serene do
  @moduledoc """
  Warm major7/minor7 pads. 12-second chord slots with smoothstep
  crossfades, hash-driven chord pool for non-repeating sequence,
  per-slot inversion + bass-octave shifts for voicing variety,
  two coprime LFOs on the pad gain.

  The "coding-music default."
  """

  @behaviour Aural.Track

  import Aural.Primitive

  @sample_rate Aural.Primitive.sample_rate()
  @chord_samples 12 * @sample_rate

  @chord_pool [
    {[261.63, 329.63, 392.00, 493.88], 65.41},
    {[220.00, 261.63, 329.63, 392.00], 55.00},
    {[174.61, 220.00, 261.63, 329.63], 87.31},
    {[196.00, 246.94, 293.66, 369.99], 49.00},
    {[164.81, 207.65, 246.94, 311.13], 82.41},
    {[146.83, 174.61, 220.00, 261.63], 73.42},
    {[233.08, 293.66, 349.23, 440.00], 58.27},
    {[155.56, 196.00, 233.08, 311.13], 77.78},
    {[164.81, 246.94, 311.13, 369.99], 41.20},
    {[220.00, 246.94, 329.63, 440.00], 55.00}
  ]
  @chord_pool_size length(@chord_pool)

  @impl true
  def sample_at(n) do
    t = n / @sample_rate

    chord_slot = div(n, @chord_samples)
    chord_progress = rem(n, @chord_samples) / @chord_samples

    {notes_a, bass_a} = chord_for_slot(chord_slot)
    {notes_b, bass_b} = chord_for_slot(chord_slot + 1)

    alpha = smoothstep(max(0.0, (chord_progress - 0.5) * 2.0))

    pad = (1.0 - alpha) * chord_sum(notes_a, t) + alpha * chord_sum(notes_b, t)
    bass = (1.0 - alpha) * sine(bass_a, t) + alpha * sine(bass_b, t)

    # Primary LFO tuned to 0.1 Hz — the resonance frequency of the
    # autonomic nervous system. Slow-breathing biofeedback aims
    # exactly here (one cycle per 10s ≈ 6 breaths/min). Listeners
    # tend to align their breath to this rhythm subconsciously,
    # which improves heart-rate variability and parasympathetic
    # tone — the "calm focus" state we want for coding. Secondary
    # LFO at coprime 0.013 Hz keeps the combined motion
    # non-periodic.
    pad_gain = 0.30 * lfo(t, 0.1, 0.85, 1.0) * lfo(t, 0.013, 0.92, 1.05)
    bass_gain = 0.18

    pad_gain * pad + bass_gain * bass
  end

  defp chord_for_slot(slot) do
    chord_idx = rem(:erlang.phash2({:chord, slot}), @chord_pool_size)
    inv = rem(:erlang.phash2({:inv, slot}), 3)
    bass_shift = bass_octave_shift(slot)
    {notes, bass} = Enum.at(@chord_pool, chord_idx)
    {invert_chord(notes, inv), bass * bass_shift}
  end

  defp bass_octave_shift(slot) do
    case rem(:erlang.phash2({:bass_oct, slot}), 5) do
      0 -> 0.5
      4 -> 2.0
      _ -> 1.0
    end
  end
end
