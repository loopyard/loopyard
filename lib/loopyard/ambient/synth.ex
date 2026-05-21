defmodule Loopyard.Ambient.Synth do
  @moduledoc """
  Dispatcher across `Loopyard.Ambient.Tracks.*`. Renders chunks of
  16-bit PCM by calling the requested track's `sample_at/1` for
  each sample index.

  ## Tracks

    * `:serene`   — warm major7/min7 pads, mid-tempo
    * `:nocturne` — dark minor-mode, slow, deeper bass
    * `:bloom`    — sparse high-register shimmer, no bass
    * `:pulse`    — Serene + slow tremolo for gentle rhythmic feel

  Defaults to `:serene`.
  """

  alias Loopyard.Ambient.Primitive

  alias Loopyard.Ambient.Tracks.{Serene, Nocturne, Bloom, Pulse}

  @tracks %{
    serene: Serene,
    nocturne: Nocturne,
    bloom: Bloom,
    pulse: Pulse
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
