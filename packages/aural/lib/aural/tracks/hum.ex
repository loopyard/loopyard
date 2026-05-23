defmodule Aural.Tracks.Hum do
  @moduledoc """
  Auditory-masking floor. No music — just deep brown-noise hiss
  plus a sustained sub-bass drone at C2 with a fifth above.

  Why this exists: meta-analyses of focus + ambient noise (Söderlund
  et al., Mehta et al.) show that **sustained spectral noise**
  consistently improves complex-task focus, primarily by flattening
  the perceptual contrast of intrusions like keyboard clatter,
  HVAC, and voices. Brown noise (steeper rolloff than pink) is the
  least fatiguing variant. This is the most-evidence-backed audio
  intervention for focus — more solid than music itself.

  Use this when you want presence without melody, or when the
  music tracks are themselves distracting.
  """

  @behaviour Aural.Track

  import Aural.Primitive

  @sample_rate Aural.Primitive.sample_rate()

  # Box-average window for the brown-noise approximation. Bigger
  # window = lower cutoff = darker, more "rumble," less hiss. A
  # 128-sample box at 48kHz has its first null at ~375Hz, which
  # pushes the perceptual character firmly into "deep brown" —
  # mostly sub-bass and low-mids, almost no audible high content.
  # CPU cost: ~6M ops/sec for the noise pass, negligible on
  # modern hardware.
  @brown_window 128

  @impl true
  def sample_at(n) do
    t = n / @sample_rate

    # Sub-bass drone: octave + fifth. Stays in 65-100Hz so it
    # leaves the entire 200Hz+ band clean for signaling tones.
    drone = sine(65.41, t) * 0.55 + sine(98.00, t) * 0.35

    # Brown noise floor. Mostly low-frequency hiss.
    brown = brown_noise(n)

    # Slow LFO at HRV-resonance 0.1 Hz so the whole bed gently
    # breathes — the room is alive but never grabs attention.
    breath = lfo(t, 0.1, 0.85, 1.0)

    (drone * 0.22 + brown * 0.16) * breath
  end

  # Deterministic brown-noise approximation: box-average white
  # noise. The averaging acts as a low-pass filter (1/f² rolloff
  # in the limit, plenty steep for the perceptual effect).
  defp brown_noise(n) do
    sum =
      Enum.reduce(0..(@brown_window - 1), 0.0, fn k, acc ->
        acc + white_noise(n - k)
      end)

    sum / @brown_window
  end

  # Stateless pseudo-random sample from sample index. `:erlang.phash2`
  # returns 0..134_217_727, recentered to [-1, 1].
  defp white_noise(n) do
    h = :erlang.phash2(n)
    (h - 67_108_863) / 67_108_864.0
  end
end
