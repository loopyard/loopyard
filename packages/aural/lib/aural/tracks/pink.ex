defmodule Aural.Tracks.Pink do
  @moduledoc """
  Pink (1/f) noise via Voss-McCartney. Distinct spectral character
  from Hum's brown (1/f²) noise: less rumble, more "shh," energy
  spread more evenly across the audible band.

  Evidence (the strongest of any single audio intervention):
    * Pink-noise stimulation during slow-wave sleep enhances next-
      day memory consolidation (Papalambros et al. 2017).
    * Steady pink-noise exposure is the audiologist's standard
      tinnitus masker.
    * Sleep / focus aids (Endel, Calm, etc.) reach for pink first.

  Why no music underneath: this track is intentionally just noise.
  If you want a bed with sub-bass + masking, use Hum (brown). Pink
  is the cleaner spectral flavor for fall-asleep or block-the-room
  use, with a very slow LFO so it doesn't feel mechanical.
  """

  @behaviour Aural.Track

  import Aural.Primitive
  import Bitwise

  @sample_rate Aural.Primitive.sample_rate()

  # 8 octave generators. Each gen `k` holds its value for 2^k
  # samples; summing all 8 approximates 1/f spectrum. 8 is the
  # standard Voss-McCartney count — more octaves change the
  # spectrum below ~190 Hz (effectively into brown territory).
  @octaves 8

  @impl true
  def sample_at(n) do
    t = n / @sample_rate

    # Slow LFO at 0.1 Hz (HRV-resonance breath rate, the same one
    # Serene uses subliminally). Without it the bed is a perfectly
    # static "shh" that brain quickly tunes out; with it there's a
    # subliminal breath rhythm that keeps it alive.
    motion = lfo(t, 0.1, 0.85, 1.0)

    pink_noise(n) * 0.45 * motion
  end

  # Voss-McCartney pink: 8 independent white sources, each updating
  # every 2^k samples. Their sum has ~1/f spectrum. Deterministic
  # per-sample evaluation: for each octave, the "bucket" the sample
  # falls into is `div(n, 2^k)`; the bucket's value is a stable
  # hash so calling sample_at(n) for the same n always returns the
  # same number.
  defp pink_noise(n) do
    sum =
      Enum.reduce(0..(@octaves - 1), 0.0, fn k, acc ->
        period = 1 <<< k
        bucket = div(n, period)
        h = :erlang.phash2({:pink, k, bucket})
        acc + (h - 67_108_863) / 67_108_864.0
      end)

    sum / @octaves
  end
end
