defmodule Aural.Synth do
  @moduledoc """
  Dispatcher across `Aural.Tracks.*`. Renders chunks of
  16-bit PCM by calling the requested track's `sample_at/1` for
  each sample index.

  ## Tracks

  These are designed as a CEREBRAL AMBIENT BASELINE — sustained
  textures with no transients or rhythmic events, intended to sit
  beneath a future audio-signaling layer (gentle alerts for things
  that need a human's attention). The music must stay out of the
  way of the signal.

    * `:serene`   — warm major7/min7 pads, mid-tempo; primary LFO
                    tuned to 0.1Hz (HRV-resonance breathing rate)
    * `:nocturne` — dark minor-mode, slow, deeper bass
    * `:cascade`  — sustained chord with rotating amplitude
                    emphasis (the chord moves upward through
                    itself, no plucks)
    * `:hum`      — auditory-masking floor: brown noise + deep
                    sub-bass drone. No music; the
                    most-evidence-backed audio intervention for
                    focus in noisy environments
    * `:gamma`    — EXPERIMENTAL: Serene + 40Hz amplitude
                    modulation for possible gamma-band entrainment

  Defaults to `:serene`.
  """

  alias Aural.Primitive

  alias Aural.Tracks.{Serene, Nocturne, Cascade, Hum, Gamma}

  @tracks %{
    serene: Serene,
    nocturne: Nocturne,
    cascade: Cascade,
    hum: Hum,
    gamma: Gamma
  }

  @doc "Names of all available tracks."
  def track_names, do: Map.keys(@tracks)

  @doc "Resolve a name (atom or string) to a track module, or nil if unknown."
  def resolve(name) when is_atom(name), do: Map.get(@tracks, name)

  def resolve(name) when is_binary(name) do
    case Map.fetch(@tracks, String.to_existing_atom(name)) do
      {:ok, mod} -> mod
      :error -> nil
    end
  rescue
    ArgumentError -> nil
  end

  def resolve(_), do: nil

  @doc "Sample rate the synth generates at (Hz)."
  def sample_rate, do: Primitive.sample_rate()

  @doc """
  Render `n_samples` of audio for the given track, starting at
  sample index `start_t`. Returns a binary of little-endian signed
  16-bit PCM (mono).

  Optional `signal_state` mixes in the ambient signal layer:
    * `:activity` (0.0-1.0) — constant bed-gain boost for the chunk.
    * `:activity_start` + `:activity_end` (each 0.0-1.0) — ramp bed
      gain linearly across the chunk. Overrides `:activity` when set.
      The Channel's per-tick easer uses this so transitions stay
      smooth sample-to-sample instead of stepping at chunk
      boundaries.
    * `:chimes` — list of `%{kind, start_n}` (sample-index relative
      to this listener's t=0) that get sample-mixed into the output
      until their per-kind lifetime expires.
  """
  def render_chunk(track, start_t, n_samples, signal_state \\ %{chimes: [], activity: 0.0})

  def render_chunk(_track, _start_t, 0, _signal_state), do: <<>>

  def render_chunk(track, start_t, n_samples, signal_state)
      when is_atom(track) and is_integer(start_t) and is_integer(n_samples) and n_samples > 0 do
    module = Map.get(@tracks, track) || Serene
    chimes = Map.get(signal_state, :chimes, [])

    # Per-sample activity ramp. Callers may pass `:activity`
    # (constant) or `:activity_start` + `:activity_end` (linear).
    # The ramp form removes audible step changes at chunk boundaries
    # while activity is tweening.
    a_start = Map.get(signal_state, :activity_start, Map.get(signal_state, :activity, 0.0))
    a_end = Map.get(signal_state, :activity_end, a_start)
    bed_gain_start = 1.0 + a_start * 0.5
    bed_gain_step = (a_end - a_start) * 0.5 / max(1, n_samples - 1)

    # Pre-compute chime lifetimes so we don't lookup per-sample.
    chime_entries =
      Enum.map(chimes, fn %{kind: kind, start_n: start_n} ->
        {kind, start_n, Aural.Signals.chime_lifetime_samples(kind)}
      end)

    for i <- 0..(n_samples - 1), into: <<>> do
      n = start_t + i
      bed_gain = bed_gain_start + bed_gain_step * i
      base = module.sample_at(n) * bed_gain
      sig = chime_contribution(chime_entries, n)
      sample = (base + sig) |> Primitive.clamp()
      <<round(sample * 32_767)::little-signed-16>>
    end
  end

  # Sum the per-sample contribution of every chime that's still alive
  # at sample index `n`.
  defp chime_contribution(chime_entries, n) do
    Enum.reduce(chime_entries, 0.0, fn {kind, start_n, lifetime}, acc ->
      age = n - start_n

      if age >= 0 and age < lifetime do
        acc + Aural.Signals.chime_sample(kind, age / 48_000)
      else
        acc
      end
    end)
  end
end
