defmodule Aural.Tracks.Gamma do
  @moduledoc """
  EXPERIMENTAL: Serene with a 40Hz amplitude modulation overlay
  for gamma-band entrainment.

  The Tsai lab at MIT (Iaccarino et al., 2016 and follow-ups) has
  shown that **40Hz visual and auditory stimulation** induces
  gamma neural oscillations and (in mice) reduces amyloid plaques.
  Human cognition effects are still being studied — the evidence
  is preliminary, not conclusive. Worth labeling honestly: this is
  a research-adjacent experiment, not a proven cognitive
  enhancement.

  Implementation: take Serene's output and modulate amplitude at
  40Hz with a 15% swing. 40Hz is too fast to perceive as rhythm
  (well above the ~10Hz flicker-fusion equivalent for hearing) —
  it sounds like a slight low buzz coloration rather than beats,
  so it doesn't break the "no transients" rule for the signaling
  layer.
  """

  @behaviour Aural.Track

  alias Aural.Tracks.Serene

  @sample_rate Aural.Primitive.sample_rate()

  @impl true
  def sample_at(n) do
    base = Serene.sample_at(n)
    t = n / @sample_rate

    # 40Hz amplitude modulation, 15% depth. Sounds like a tonal
    # coloration, not beats — perfect for "background entrainment
    # that doesn't compete with signaling" if the entrainment
    # effect is real.
    mod = 0.85 + 0.15 * :math.sin(2.0 * :math.pi * 40.0 * t)

    base * mod
  end
end
