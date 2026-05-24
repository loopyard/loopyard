defmodule Aural.Tracks.VagalDrone do
  @moduledoc """
  EXPERIMENTAL: pure sub-bass drone, no music. A stack of three
  sines at 55 / 82.41 / 110 Hz (A1, E2, A2) — root + perfect fifth
  + octave, all below 200 Hz so nothing competes with mid-range
  signaling tones in the rest of the channel.

  Why the vagal-resonance framing: low-frequency vibroacoustic
  stimulation has a body of (small) studies suggesting
  parasympathetic activation, particularly when delivered through
  body-coupled transducers (Patrick on physioacoustic therapy,
  Skille's vibroacoustic work). The evidence is thinner than even
  Gamma's, and the protocols used in research deliver bass through
  haptic chairs — through earbuds this just reads as a deep hum.

  Pair with on-body speakers / subwoofer for any chance at the
  vibrational effect; otherwise it's a meditation bed with zero
  mid-range content to distract from concentration.
  """

  @behaviour Aural.Track

  import Aural.Primitive

  @sample_rate Aural.Primitive.sample_rate()

  @impl true
  def sample_at(n) do
    t = n / @sample_rate

    # A1 + E2 + A2. The fifth (E2 = 82.41 Hz) adds harmonic interest
    # without the third — neither major nor minor, just "open." The
    # octave (A2) gives the stack some perceptible body even on
    # speakers that roll off below 80 Hz.
    root = sine(55.0, t)
    fifth = sine(82.41, t)
    octave = sine(110.0, t)

    # Glacial 0.05 Hz LFO (20s cycle) — slower than HRV-resonance,
    # so the bed "breathes" without pacing anything. Want it to
    # feel like a room hum, not a metronome.
    motion = lfo(t, 0.05, 0.85, 1.0)

    (root * 0.30 + fifth * 0.18 + octave * 0.20) * motion
  end
end
