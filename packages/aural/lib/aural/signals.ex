defmodule Aural.Signals do
  @moduledoc """
  Chime voice library — the per-sample synthesis for the three
  alert sounds (done, attention, alert). Used by
  `Aural.ChimeAssets` to render WAV files at app boot,
  which the browser then preloads and plays locally for instant
  server-pushed alerts.

  No state, no ETS — these are pure functions. State (track,
  activity, alert routing) lives on `Aural.Channel`.
  """

  alias Aural.Primitive

  @sample_rate Primitive.sample_rate()

  # Sample lifetimes per chime kind, in seconds.
  @chime_lifetime_s %{
    "done" => 3.5,
    "attention" => 2.5,
    "alert" => 1.2
  }

  @doc """
  Sample contribution from a single chime at the given age (in
  seconds since the chime fired). Returns a float roughly in
  [-1.0, 1.0].
  """
  def chime_sample("done", t) do
    # Major triad bell — C5 + E5 + G5, exponential decay.
    env = bell_envelope(t, 2.0)
    voices = (sine(523.25, t) + sine(659.25, t) + sine(783.99, t)) / 3.0
    voices * env * 0.30
  end

  def chime_sample("attention", t) do
    # Single bowed A4 with a slow attack and slow decay.
    env = bow_envelope(t, 0.25, 1.5)
    sine(440.00, t) * env * 0.25
  end

  def chime_sample("alert", t) do
    # Minor 2nd dyad (E5 + F5) — built-in dissonance reads as
    # "something needs attention" without being harsh.
    env = bell_envelope(t, 0.6)
    voices = (sine(659.25, t) + sine(698.46, t)) / 2.0
    voices * env * 0.28
  end

  def chime_sample(_, _), do: 0.0

  @doc "Lifetime of a chime in samples (drives WAV-render length)."
  def chime_lifetime_samples(kind) do
    secs = Map.get(@chime_lifetime_s, kind, 0.0)
    trunc(secs * @sample_rate)
  end

  # --- Voice helpers ---

  defp sine(freq, t), do: :math.sin(2.0 * :math.pi * freq * t)

  # Bell: hit fast, decay exponentially. `tau` controls how quickly
  # it rings out (higher = longer ring).
  defp bell_envelope(t, tau) when t >= 0.0 do
    # 5ms attack ramp to avoid click, then exponential decay.
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
end
