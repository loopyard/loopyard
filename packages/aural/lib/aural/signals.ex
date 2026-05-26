defmodule Aural.Signals do
  @moduledoc """
  Chime voice library — pure per-sample synthesis for the three
  alert sounds (done, attention, alert). Channel mixes these into
  the bed PCM stream per-sample (no local-WAV path); bed + chimes
  share a single ffmpeg encoder so the harmonic integration is
  mathematical, not "two audio sources happening to overlap."

  Envelopes apply both their voice-specific shape (bell exponential
  decay, bow attack/sustain/release) AND a smoothstep tail fadeout
  in the last 300 ms of the chime's lifetime. Without the tail
  fadeout, exp decay would still be at ~10-17% amplitude when the
  Channel drops the chime from its active list — audibly clipping
  the tail. The smoothstep ramps that residual to zero.

  No state, no ETS — pure functions of `(kind, t)`.
  """

  alias Aural.Primitive

  @sample_rate Primitive.sample_rate()

  # Lifetimes in seconds. The Channel drops a chime when its age
  # passes this value. Longer than the old WAV-rendered versions
  # (5.0 / 3.0 / 1.8 vs 3.5 / 2.5 / 1.2) because stream-mixing has
  # no file-size cost — the chime just stops contributing per-sample
  # once its envelope ramps to zero.
  @chime_lifetime_s %{
    "done" => 5.0,
    "attention" => 3.0,
    "alert" => 1.8
  }

  # Tail-taper window: last N seconds of the lifetime where the
  # smoothstep fade applies. 0.3 s ramps even moderate residuals
  # (~10-15%) cleanly to zero while leaving the voice's natural
  # decay intact for the rest of the duration.
  @fadeout_window 0.3

  @doc """
  Per-sample contribution from a single chime at age `t` seconds
  since the chime fired. Returns a float roughly in `[-1.0, 1.0]`.
  """
  def chime_sample(kind, t) when is_binary(kind) and is_number(t) and t >= 0.0 do
    lifetime = Map.get(@chime_lifetime_s, kind, 0.0)

    if t >= lifetime do
      0.0
    else
      chime_voice(kind, t) * tail_fadeout(t, lifetime)
    end
  end

  def chime_sample(_, _), do: 0.0

  @doc "Lifetime of a chime in samples. Channel uses this to prune expired entries."
  def chime_lifetime_samples(kind) do
    secs = Map.get(@chime_lifetime_s, kind, 0.0)
    trunc(secs * @sample_rate)
  end

  @doc "All known chime kinds."
  def kinds, do: Map.keys(@chime_lifetime_s)

  # --- Per-voice shapes ---

  # Major triad bell, C5 + E5 + G5, exponential decay.
  defp chime_voice("done", t) do
    env = bell_envelope(t, 2.0)
    voices = (sine(523.25, t) + sine(659.25, t) + sine(783.99, t)) / 3.0
    voices * env * 0.30
  end

  # Single bowed A4 with a slow attack and slow decay.
  defp chime_voice("attention", t) do
    env = bow_envelope(t, 0.25, 1.5)
    sine(440.00, t) * env * 0.25
  end

  # Minor 2nd dyad (E5 + F5) — built-in dissonance reads as
  # "something needs attention" without being harsh.
  defp chime_voice("alert", t) do
    env = bell_envelope(t, 0.6)
    voices = (sine(659.25, t) + sine(698.46, t)) / 2.0
    voices * env * 0.28
  end

  defp chime_voice(_, _), do: 0.0

  # --- Envelope primitives ---

  defp sine(freq, t), do: :math.sin(2.0 * :math.pi * freq * t)

  # Bell: 5 ms attack ramp to avoid click, then exp decay at `tau`.
  defp bell_envelope(t, tau) when t >= 0.0 do
    attack = min(t / 0.005, 1.0)
    decay = :math.exp(-t / tau)
    attack * decay
  end

  defp bell_envelope(_, _), do: 0.0

  # Bow: gentle attack, sustain near 1.0, gentle release.
  defp bow_envelope(t, attack_s, release_s) when t >= 0.0 do
    cond do
      t < attack_s -> Primitive.smoothstep(t / attack_s)
      t < attack_s + 0.5 -> 1.0
      true -> 1.0 - Primitive.smoothstep((t - attack_s - 0.5) / release_s)
    end
  end

  defp bow_envelope(_, _, _), do: 0.0

  # Smoothstep taper to zero across the last @fadeout_window
  # seconds of the chime's lifetime; 1.0 elsewhere so the voice's
  # own envelope shape stays intact.
  defp tail_fadeout(t, lifetime) do
    fadeout_start = lifetime - @fadeout_window

    if t > fadeout_start do
      max(0.0, 1.0 - Primitive.smoothstep((t - fadeout_start) / @fadeout_window))
    else
      1.0
    end
  end
end
