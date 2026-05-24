defmodule Aural.Tracks.Theta do
  @moduledoc """
  EXPERIMENTAL: Serene with a 6 Hz amplitude modulation overlay.
  Sibling to Gamma but one EEG band slower — 6 Hz sits in the
  theta band, associated with meditative states, memory encoding,
  and creative incubation.

  Auditory entrainment evidence is mixed: some EEG studies show
  modest theta-band entrainment from acoustic stimulation at this
  rate (Wahbeh et al., Lustenberger et al. for analogues);
  behavioural cognitive effects are harder to replicate. Worth
  labelling as research-adjacent, not proven.

  Implementation mirrors Gamma — modulate Serene's output by a
  sine wave — except at 6 Hz instead of 40 Hz. 6 Hz is below the
  flicker-fusion threshold for hearing, so it reads as slow
  tremolo rather than tonal coloration. Modulation depth is a
  bit higher than Gamma (30% vs 15%) because the audible tremolo
  IS the entrainment claim — masking it would make this just a
  quieter Serene.
  """

  @behaviour Aural.Track

  alias Aural.Tracks.Serene

  @sample_rate Aural.Primitive.sample_rate()

  @impl true
  def sample_at(n) do
    base = Serene.sample_at(n)
    t = n / @sample_rate

    # 6 Hz amplitude modulation, 30% depth.
    mod = 0.70 + 0.30 * :math.sin(2.0 * :math.pi * 6.0 * t)

    base * mod
  end
end
