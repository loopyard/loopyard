defmodule Loopyard.Ambient.Tracks.Cascade do
  @moduledoc """
  Loscil-style ascending motion on a sustained pad. No discrete
  notes — all chord notes play continuously, but each note has its
  own slow amplitude LFO phased so they peak in ascending order
  (low note brightest first, then middle, then high, then highest,
  loop). The listener perceives the chord moving upward through
  itself, the way Bach preludes *feel* like they always go up,
  but without any plucked transients.

  Sustained bass underneath. No tremolo, no harmonics — just pure
  sines blooming gently in sequence.
  """

  @behaviour Loopyard.Ambient.Track

  import Loopyard.Ambient.Primitive

  @sample_rate Loopyard.Ambient.Primitive.sample_rate()
  @slot_samples 20 * @sample_rate

  # The ascending-spotlight period. Each chord note peaks once per
  # cycle; the cycle takes this many seconds to traverse all four
  # notes. 24s = 6s per "step" — slow enough to feel meditative,
  # fast enough that the upward motion is perceptible.
  @rotation_period_s 24.0

  # Diatonic-feeling pool, same shape as Serene.
  @chord_pool [
    {[261.63, 329.63, 392.00, 493.88], 65.41},
    {[220.00, 261.63, 329.63, 392.00], 55.00},
    {[174.61, 220.00, 261.63, 329.63], 87.31},
    {[196.00, 246.94, 293.66, 369.99], 49.00},
    {[164.81, 207.65, 246.94, 311.13], 82.41},
    {[146.83, 174.61, 220.00, 261.63], 73.42}
  ]
  @chord_pool_size length(@chord_pool)

  @impl true
  def sample_at(n) do
    t = n / @sample_rate

    chord_slot = div(n, @slot_samples)
    chord_progress = rem(n, @slot_samples) / @slot_samples

    {notes_a, bass_a} = chord_for_slot(chord_slot)
    {notes_b, bass_b} = chord_for_slot(chord_slot + 1)

    alpha = smoothstep(max(0.0, (chord_progress - 0.7) * 3.33))

    # Each chord note has its own amplitude LFO. Phase offset by
    # note position so they peak in ascending order across the
    # rotation period.
    arp_a = ascending_spotlight(notes_a, t)
    arp_b = ascending_spotlight(notes_b, t)

    pad = (1.0 - alpha) * arp_a + alpha * arp_b
    bass = (1.0 - alpha) * sine(bass_a, t) + alpha * sine(bass_b, t)

    # Slow gain LFO on the whole thing for natural breath. No
    # tremolo or harmonics.
    pad_gain = 0.22 * lfo(t, 0.03, 0.85, 1.0)
    bass_gain = 0.15

    pad_gain * pad + bass_gain * bass
  end

  # All chord notes play continuously, but each has an amplitude
  # that swells in turn. Phase offsets by note index so they peak
  # in ascending sequence over @rotation_period_s.
  defp ascending_spotlight(notes, t) do
    count = length(notes)

    notes
    |> Enum.with_index()
    |> Enum.reduce(0.0, fn {freq, idx}, acc ->
      phase = idx / count * 2.0 * :math.pi
      # Cosine ranges -1..1; shift to 0..1 with a floor so even
      # "off" notes contribute a little (smooth cloud, not gating).
      amp_lfo = 0.35 + 0.65 * (1.0 + :math.cos(2.0 * :math.pi * t / @rotation_period_s - phase)) / 2.0
      acc + sine(freq, t) * amp_lfo
    end)
    |> Kernel./(count)
  end

  defp chord_for_slot(slot) do
    idx = rem(:erlang.phash2({:cascade, slot}), @chord_pool_size)
    Enum.at(@chord_pool, idx)
  end
end
