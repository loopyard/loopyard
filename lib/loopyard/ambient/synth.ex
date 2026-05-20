defmodule Loopyard.Ambient.Synth do
  @moduledoc """
  Pure-functions ambient synth. Generates 16-bit signed PCM samples
  from a sample index — no state, no GenServer, no PubSub.

  Used by the HTTP streaming controller
  (`LoopyardWeb.AmbientStreamController`) and the standalone WAV
  script (`scripts/ambient_wav.exs`).

  Each listener has their own integer sample counter `t`. Render the
  next chunk with `render_chunk(t, n_samples)`, advance `t` by
  `n_samples`, repeat. The synth itself never tracks anything across
  calls.

  See `plans/ambient-soundtrack.md` for the design rationale.
  """

  @sample_rate 48_000
  @chord_samples 12 * @sample_rate

  # Pool of harmonically-compatible chords. The synth picks one per
  # 12-second slot via a hash of the slot index, so the order doesn't
  # repeat in a short window — feels "evolving" rather than looping.
  # All chords share enough notes that consecutive transitions stay
  # consonant for ambient.
  @chord_pool [
    # Cmaj7 + C bass
    {[261.63, 329.63, 392.00, 493.88], 65.41},
    # Am7 + A bass
    {[220.00, 261.63, 329.63, 392.00], 55.00},
    # Fmaj7 + F bass (low octave)
    {[174.61, 220.00, 261.63, 329.63], 87.31},
    # G6 + G bass (low octave)
    {[196.00, 246.94, 293.66, 369.99], 49.00},
    # Em7 + E bass
    {[164.81, 207.65, 246.94, 311.13], 82.41},
    # Dm9 + D bass
    {[146.83, 174.61, 220.00, 261.63], 73.42},
    # Bbmaj7 + Bb bass
    {[233.08, 293.66, 349.23, 440.00], 58.27},
    # Ebmaj9 + Eb bass
    {[155.56, 196.00, 233.08, 311.13], 77.78},
    # Em(add9) / Cmaj7-rooted-on-E feel
    {[164.81, 246.94, 311.13, 369.99], 41.20},
    # Asus2 + A bass
    {[220.00, 246.94, 329.63, 440.00], 55.00}
  ]
  @chord_pool_size length(@chord_pool)

  @doc "Sample rate the synth generates at."
  def sample_rate, do: @sample_rate

  @doc """
  Render `n_samples` of audio starting at sample index `start_t`.
  Returns a binary of little-endian signed 16-bit PCM (mono).
  """
  def render_chunk(_start_t, 0), do: <<>>

  def render_chunk(start_t, n_samples)
      when is_integer(start_t) and is_integer(n_samples) and n_samples > 0 do
    for i <- 0..(n_samples - 1), into: <<>> do
      sample = sample_at(start_t + i) |> clamp()
      <<round(sample * 32_767)::little-signed-16>>
    end
  end

  # Sample value at integer index `n`. No cycle — chord_for_slot/1
  # is a deterministic hash of the slot index, so the chord sequence
  # is non-repeating in any audible window.
  defp sample_at(n) do
    t = n / @sample_rate

    chord_slot = div(n, @chord_samples)
    chord_progress = rem(n, @chord_samples) / @chord_samples

    {notes_a, bass_a} = chord_for_slot(chord_slot)
    {notes_b, bass_b} = chord_for_slot(chord_slot + 1)

    alpha = smoothstep(max(0.0, (chord_progress - 0.5) * 2.0))

    pad = (1.0 - alpha) * chord_sum(notes_a, t) + alpha * chord_sum(notes_b, t)
    bass = (1.0 - alpha) * sine(bass_a, t) + alpha * sine(bass_b, t)

    # Two LFOs at coprime-ish frequencies. Their product is
    # non-periodic over any audible window — no obvious "breath in,
    # breath out" pattern.
    pad_gain = 0.30 * lfo(t, 0.07, 0.85, 1.0) * lfo(t, 0.013, 0.92, 1.05)
    bass_gain = 0.18

    pad_gain * pad + bass_gain * bass
  end

  # Pick a chord from the pool deterministically, plus an inversion
  # and bass-octave shift — all keyed off independent hashes of the
  # slot so they don't correlate. The combined space is
  # 10 chords × 3 inversions × 3 bass octaves = 90 distinct
  # voicings, picked seemingly at random across the slot sequence.
  # The bass octave variation specifically breaks up the
  # "down-down-down" directional drift you'd hear with bass notes
  # only ever in one octave.
  defp chord_for_slot(slot) do
    chord_idx = rem(:erlang.phash2({:chord, slot}), @chord_pool_size)
    inv = rem(:erlang.phash2({:inv, slot}), 3)
    bass_shift = bass_octave_shift(slot)

    {notes, bass} = Enum.at(@chord_pool, chord_idx)
    {invert_chord(notes, inv), bass * bass_shift}
  end

  # Distribution: ~60% default octave, ~20% down, ~20% up.
  defp bass_octave_shift(slot) do
    case rem(:erlang.phash2({:bass_oct, slot}), 5) do
      0 -> 0.5
      4 -> 2.0
      _ -> 1.0
    end
  end

  # Rotate the chord N positions, moving each rotated note up one
  # octave. Changes the voicing — actually changes what frequencies
  # sound — unlike a plain list rotation (which would be silent
  # since we just sum the sines).
  defp invert_chord(notes, 0), do: notes

  defp invert_chord([lowest | rest], k) when k > 0 do
    invert_chord(rest ++ [lowest * 2], k - 1)
  end

  defp chord_sum(notes, t) do
    Enum.reduce(notes, 0.0, fn f, acc -> acc + sine(f, t) end) / length(notes)
  end

  defp sine(freq, t), do: :math.sin(2 * :math.pi * freq * t)

  defp lfo(t, freq_hz, low, high) do
    mid = (low + high) / 2
    amp = (high - low) / 2
    mid + amp * :math.sin(2 * :math.pi * freq_hz * t)
  end

  defp smoothstep(x) when x <= 0.0, do: 0.0
  defp smoothstep(x) when x >= 1.0, do: 1.0
  defp smoothstep(x), do: x * x * (3.0 - 2.0 * x)

  defp clamp(v) when v > 1.0, do: 1.0
  defp clamp(v) when v < -1.0, do: -1.0
  defp clamp(v), do: v
end
