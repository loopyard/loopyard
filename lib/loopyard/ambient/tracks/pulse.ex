defmodule Loopyard.Ambient.Tracks.Pulse do
  @moduledoc """
  Same warm chord palette as Serene, plus a slow tremolo on the
  pad (amplitude modulation at ~0.5 Hz). Gives a gentle rhythmic
  pulse — useful for keeping you in the chair without going full
  beat-driven. Faster chord slots (8s) than Serene for slightly
  more motion.
  """

  @behaviour Loopyard.Ambient.Track

  import Loopyard.Ambient.Primitive

  @sample_rate Loopyard.Ambient.Primitive.sample_rate()
  @chord_samples 8 * @sample_rate

  # Same chord palette as Serene.
  @chord_pool [
    {[261.63, 329.63, 392.00, 493.88], 65.41},
    {[220.00, 261.63, 329.63, 392.00], 55.00},
    {[174.61, 220.00, 261.63, 329.63], 87.31},
    {[196.00, 246.94, 293.66, 369.99], 49.00},
    {[164.81, 207.65, 246.94, 311.13], 82.41},
    {[146.83, 174.61, 220.00, 261.63], 73.42},
    {[233.08, 293.66, 349.23, 440.00], 58.27},
    {[155.56, 196.00, 233.08, 311.13], 77.78}
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

    # Tremolo: amplitude modulation at 0.5 Hz with a wide swing
    # (depth 0.5). Combined with the regular LFO this gives a
    # breathing-pulse feel without going full beat.
    tremolo = lfo(t, 0.5, 0.5, 1.0)
    pad_gain = 0.30 * tremolo * lfo(t, 0.07, 0.85, 1.0)
    bass_gain = 0.20

    pad_gain * pad + bass_gain * bass
  end

  defp chord_for_slot(slot) do
    chord_idx = rem(:erlang.phash2({:pulse_chord, slot}), @chord_pool_size)
    inv = rem(:erlang.phash2({:pulse_inv, slot}), 3)
    {notes, bass} = Enum.at(@chord_pool, chord_idx)
    {invert_chord(notes, inv), bass}
  end
end
