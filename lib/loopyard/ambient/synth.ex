defmodule Loopyard.Ambient.Synth do
  @moduledoc """
  Dispatcher across `Loopyard.Ambient.Tracks.*`. Renders chunks of
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

  alias Loopyard.Ambient.Primitive

  alias Loopyard.Ambient.Tracks.{Serene, Nocturne, Cascade, Hum, Gamma}

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
  """
  def render_chunk(_track, _start_t, 0), do: <<>>

  def render_chunk(track, start_t, n_samples)
      when is_atom(track) and is_integer(start_t) and is_integer(n_samples) and n_samples > 0 do
    module = Map.get(@tracks, track) || Serene

    for i <- 0..(n_samples - 1), into: <<>> do
      sample = module.sample_at(start_t + i) |> Primitive.clamp()
      <<round(sample * 32_767)::little-signed-16>>
    end
  end
end
