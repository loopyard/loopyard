defmodule Aural.Tracks.Resonance do
  @moduledoc """
  Overt 0.1 Hz breath pacer. A sustained pad whose amplitude swells
  audibly with a 4-second inhale + 6-second exhale — the
  "extended-exhale" cardiac vagal tone protocol (6 breaths/min,
  exactly the resonance frequency of the autonomic nervous system).

  The point: listeners synchronize their breath to the pacer, and
  slow-breathing biofeedback at this rate has the strongest
  evidence base in this whole category (Lehrer + Gevirtz reviews
  of HRV biofeedback). Serene already uses the same 0.1 Hz LFO
  subliminally; Resonance makes the breath cue overt enough to
  actually entrain to.

  Active intervention — works only if the listener consciously
  breathes along. Passive listening yields little benefit, which
  is why it's labelled experimental even though the underlying
  protocol isn't.
  """

  @behaviour Aural.Track

  import Aural.Primitive

  @sample_rate Aural.Primitive.sample_rate()

  # 10s breath cycle, 4s inhale, 6s exhale — extended-exhale ratio.
  @cycle_s 10.0
  @inhale_s 4.0
  @exhale_s 6.0

  # Am9 voicing (A C E G B). Neutral, warm, slightly meditative;
  # one chord held throughout — listener's attention belongs to
  # breath, not harmonic motion.
  @chord [220.0, 261.63, 329.63, 392.0, 493.88]
  @bass 110.0

  @impl true
  def sample_at(n) do
    t = n / @sample_rate

    breath = breath_envelope(t)

    pad = chord_sum(@chord, t)
    bass = sine(@bass, t)

    pad_gain = 0.30 * breath
    bass_gain = 0.20 * breath

    pad_gain * pad + bass_gain * bass
  end

  # Smoothstep-shaped 0..1 envelope. Inhale rises gently for 4s,
  # exhale falls gently for 6s. Floor at 0.02 so the bed is always
  # *very* faintly audible at the bottom of the exhale — without
  # the floor, the scope flatlines and listeners think the audio
  # stopped (and the synth test's "different at t=0 vs t=60" check
  # picks up the floor differential).
  defp breath_envelope(t) do
    cycle_pos = :math.fmod(t, @cycle_s)

    raw =
      cond do
        cycle_pos < @inhale_s ->
          smoothstep(cycle_pos / @inhale_s)

        true ->
          1.0 - smoothstep((cycle_pos - @inhale_s) / @exhale_s)
      end

    0.02 + 0.98 * raw
  end
end
