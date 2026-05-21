defmodule Loopyard.Ambient.Tracks.Cascade do
  @moduledoc """
  Bach prelude-inspired ascending arpeggios. Each 8-second chord
  slot plays the chord as an 8-note ascending sequence (the chord
  notes followed by the same notes an octave higher), then resets
  to the next chord's low note and climbs again. The constant
  "reset and rise" is what makes Bach preludes feel like they
  always go up.

  Tempo: 1 note per second — slow enough to stay chill, fast
  enough for the upward motion to register. Plucked envelope
  (fast attack, exponential decay) + a hint of second/third
  harmonics gives a soft harpsichord-ish timbre. Sustained bass
  holds the harmonic floor underneath.
  """

  @behaviour Loopyard.Ambient.Track

  import Loopyard.Ambient.Primitive

  @sample_rate Loopyard.Ambient.Primitive.sample_rate()
  @slot_samples 8 * @sample_rate
  @notes_per_slot 8
  @note_samples div(@slot_samples, @notes_per_slot)

  # Diatonic-feeling chord pool. Major/minor 7ths in related keys.
  # Random selection per slot (no V-I logic) but the limited
  # palette keeps it tonal.
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

    slot = div(n, @slot_samples)
    in_slot = rem(n, @slot_samples)

    {chord_notes, bass_freq} = chord_for_slot(slot)

    # Ascending arpeggio: chord notes, then same notes one octave up.
    # 4 + 4 = 8 ascending positions across the slot.
    arp_notes = chord_notes ++ Enum.map(chord_notes, &(&1 * 2.0))

    note_idx = min(div(in_slot, @note_samples), length(arp_notes) - 1)
    note_freq = Enum.at(arp_notes, note_idx)
    in_note = rem(in_slot, @note_samples) / @note_samples

    # Pluck envelope: ~20ms attack (no click), exponential decay
    # over the ~1s note. Notes overlap their own tails naturally,
    # giving a continuous flow without crossfades.
    envelope = pluck_envelope(in_note)

    arp = pluck_voice(note_freq, t) * envelope
    bass = sine(bass_freq, t)

    arp * 0.30 + bass * 0.15
  end

  # Plucked tone: fundamental + light 2nd and 3rd harmonics for a
  # soft harpsichord-ish brightness. All sines so it stays clean.
  defp pluck_voice(freq, t) do
    sine(freq, t) + 0.30 * sine(freq * 2.0, t) + 0.12 * sine(freq * 3.0, t)
  end

  # 2% attack ramp then exponential decay. Time constant ~2.5
  # samples through the note gives a soft, mostly-rung-out tail
  # by the end of the 1-second window.
  defp pluck_envelope(p) when p < 0.02, do: p / 0.02
  defp pluck_envelope(p), do: :math.exp(-(p - 0.02) * 2.5)

  defp chord_for_slot(slot) do
    idx = rem(:erlang.phash2({:cascade, slot}), @chord_pool_size)
    Enum.at(@chord_pool, idx)
  end
end
