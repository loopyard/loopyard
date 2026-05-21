defmodule Loopyard.Ambient.Tracks.Nocturne do
  @moduledoc """
  Dark, slow, minor-mode ambient. 16-second chord slots (slower
  than Serene). All chords are minor 7th / minor 9th voicings.
  Deeper bass — most slots drop an octave below Serene's range.
  Slower LFOs for a more glacial feel.
  """

  @behaviour Loopyard.Ambient.Track

  import Loopyard.Ambient.Primitive

  @sample_rate Loopyard.Ambient.Primitive.sample_rate()
  @chord_samples 16 * @sample_rate

  # Minor chord pool. Notes are mostly in the same octave as Serene
  # but the BASS is one octave lower than Serene's equivalent root
  # for that darker tone.
  @chord_pool [
    # Am9: A C E G B
    {[220.00, 261.63, 329.63, 392.00, 493.88], 27.50},
    # Em9: E G B D F#
    {[164.81, 196.00, 246.94, 293.66, 369.99], 41.20},
    # Dm9: D F A C E
    {[146.83, 174.61, 220.00, 261.63, 329.63], 36.71},
    # Bm7: B D F# A
    {[246.94, 293.66, 369.99, 440.00], 30.87},
    # F#m7: F# A C# E
    {[185.00, 220.00, 277.18, 329.63], 23.12},
    # Gm9: G Bb D F A
    {[196.00, 233.08, 293.66, 349.23, 440.00], 24.50},
    # Cm9: C Eb G Bb D
    {[261.63, 311.13, 392.00, 466.16, 587.33], 32.70},
    # Fm9: F Ab C Eb G
    {[174.61, 207.65, 261.63, 311.13, 392.00], 21.83}
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

    # Slower LFOs than Serene — glacial motion.
    pad_gain = 0.22 * lfo(t, 0.04, 0.80, 1.0) * lfo(t, 0.011, 0.92, 1.05)
    # More bass presence than Serene — the deep tone is the point.
    bass_gain = 0.28

    pad_gain * pad + bass_gain * bass
  end

  defp chord_for_slot(slot) do
    chord_idx = rem(:erlang.phash2({:noc_chord, slot}), @chord_pool_size)
    inv = rem(:erlang.phash2({:noc_inv, slot}), 3)
    {notes, bass} = Enum.at(@chord_pool, chord_idx)
    {invert_chord(notes, inv), bass}
  end
end
