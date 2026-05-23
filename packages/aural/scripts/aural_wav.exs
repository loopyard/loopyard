# Generate a 10-second ambient pad + bass WAV to ~/Downloads.
#
# Standalone proof of concept for plans/aural.md.
# Pure Elixir, no deps. Run with: elixir scripts/aural_wav.exs

sample_rate = 44_100
duration_s = 10
total_samples = sample_rate * duration_s

# Two chords. Crossfade between them over the 10 seconds gives the
# slow harmonic motion that makes ambient feel alive.
cmaj7 = [261.63, 329.63, 392.00, 493.88]
fmaj9 = [349.23, 440.00, 523.25, 587.33]

# Bass notes one octave below the chord root.
bass_c = 65.41
bass_f = 87.31

sine = fn freq, t -> :math.sin(2 * :math.pi * freq * t) end

chord = fn notes, t ->
  Enum.reduce(notes, 0.0, fn f, acc -> acc + sine.(f, t) end) / length(notes)
end

# Fade in over first 1.5s, fade out over last 1.5s. Smooths the
# start/stop and prevents click-pop on transitions.
envelope = fn t ->
  cond do
    t < 1.5 -> t / 1.5
    t > duration_s - 1.5 -> (duration_s - t) / 1.5
    true -> 1.0
  end
end

# Smooth crossfade (S-curve) over the full duration.
crossfade = fn t ->
  x = t / duration_s
  # Smoothstep: 3x² - 2x³ — gentler than linear
  x * x * (3.0 - 2.0 * x)
end

# Slow LFO at 0.07 Hz adds gentle motion to the pad gain (~14s period,
# longer than the file so you hear an inhale-only).
lfo = fn t -> 0.85 + 0.15 * :math.sin(2 * :math.pi * 0.07 * t) end

sample_at = fn n ->
  t = n / sample_rate
  alpha = crossfade.(t)

  pad = (1.0 - alpha) * chord.(cmaj7, t) + alpha * chord.(fmaj9, t)
  bass = (1.0 - alpha) * sine.(bass_c, t) + alpha * sine.(bass_f, t)

  raw = 0.30 * pad * lfo.(t) + 0.18 * bass
  enveloped = raw * envelope.(t)

  max(-1.0, min(1.0, enveloped))
end

IO.puts("Rendering #{duration_s}s at #{sample_rate}Hz mono (#{total_samples} samples)...")
{render_us, samples_iolist} =
  :timer.tc(fn ->
    for n <- 0..(total_samples - 1) do
      s = sample_at.(n)
      <<round(s * 32_767)::little-signed-16>>
    end
  end)

samples = IO.iodata_to_binary(samples_iolist)
data_size = byte_size(samples)

IO.puts("Render took #{Float.round(render_us / 1000, 1)}ms (#{Float.round(data_size / 1024, 1)} KB PCM)")

# RIFF/WAVE header — mono, 16-bit PCM.
header =
  [
    "RIFF",
    <<36 + data_size::little-32>>,
    "WAVE",
    "fmt ",
    <<16::little-32, 1::little-16, 1::little-16, sample_rate::little-32,
      sample_rate * 2::little-32, 2::little-16, 16::little-16>>,
    "data",
    <<data_size::little-32>>
  ]
  |> IO.iodata_to_binary()

out_dir = Path.expand("~/Downloads")
out_path = Path.join(out_dir, "loopyard-aural-#{:os.system_time(:second)}.wav")
File.write!(out_path, [header, samples])

total_kb = Float.round(byte_size(header <> samples) / 1024, 1)
IO.puts("\n✓ Wrote #{out_path}")
IO.puts("  #{total_kb} KB. Open with QuickTime / VLC / Audacity / `afplay`.")
