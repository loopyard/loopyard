defmodule Loopyard.Ambient.Tracks.Bloom do
  @moduledoc """
  Sparse high-register ambient. No bass. 22-second chord slots —
  very slow. Stacked 5ths / sus2 / quartal voicings for an
  ambiguous, open-feeling harmony. Notes are an octave higher than
  Serene's voicings. Just pure shimmer — coding music for when
  you want air, not warmth.
  """

  @behaviour Loopyard.Ambient.Track

  import Loopyard.Ambient.Primitive

  @sample_rate Loopyard.Ambient.Primitive.sample_rate()
  @chord_samples 22 * @sample_rate

  # Open / sus / quartal voicings. Notes in the 400-1000Hz range
  # for that "halo" feel. No bass note tracked (sample_at returns
  # 0 for bass contribution).
  @chord_pool [
    # Csus2: C D G + high C
    {[523.25, 587.33, 783.99, 1046.50]},
    # Asus2
    {[440.00, 493.88, 659.25, 880.00]},
    # F quartal: F Bb Eb
    {[349.23, 466.16, 622.25, 698.46]},
    # Gsus4: G C D + G
    {[392.00, 523.25, 587.33, 783.99]},
    # Dsus2: D E A D
    {[293.66, 329.63, 440.00, 587.33]},
    # E open: E B E G#
    {[329.63, 493.88, 659.25, 830.61]},
    # Bb quartal
    {[466.16, 622.25, 830.61, 932.33]},
    # Eb open: Eb Bb Eb G
    {[311.13, 466.16, 622.25, 783.99]}
  ]
  @chord_pool_size length(@chord_pool)

  @impl true
  def sample_at(n) do
    t = n / @sample_rate

    chord_slot = div(n, @chord_samples)
    chord_progress = rem(n, @chord_samples) / @chord_samples

    {notes_a} = chord_for_slot(chord_slot)
    {notes_b} = chord_for_slot(chord_slot + 1)

    alpha = smoothstep(max(0.0, (chord_progress - 0.5) * 2.0))

    pad = (1.0 - alpha) * chord_sum(notes_a, t) + alpha * chord_sum(notes_b, t)

    # Very slow LFOs. Gain is gentler than Serene — the high
    # register doesn't need much to be present.
    pad_gain = 0.20 * lfo(t, 0.03, 0.75, 1.0) * lfo(t, 0.017, 0.90, 1.0)

    pad_gain * pad
  end

  defp chord_for_slot(slot) do
    chord_idx = rem(:erlang.phash2({:bloom_chord, slot}), @chord_pool_size)
    inv = rem(:erlang.phash2({:bloom_inv, slot}), 3)
    {notes} = Enum.at(@chord_pool, chord_idx)
    {invert_chord(notes, inv)}
  end
end
