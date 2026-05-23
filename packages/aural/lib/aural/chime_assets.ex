defmodule Aural.ChimeAssets do
  @moduledoc """
  Pre-renders the three chime sounds to WAV files in
  `priv/static/chimes/`. The browser preloads them and plays the
  matching one instantly when the server pushes an `alert` event
  over the LiveView WebSocket — bypassing the 2-5s buffer that the
  streaming MP3 bed carries.

  Same voice functions as `Aural.Signals.chime_sample/2`,
  so the chime you hear instantly is the same chime that *would*
  have been mixed into the bed (the bed-mixing path is no longer
  used for chimes — the latency made it useless as an alert).
  """

  alias Aural.{Primitive, Signals}

  @kinds ["done", "attention", "alert"]
  @sample_rate Primitive.sample_rate()

  @doc """
  Render every chime to its WAV file if not already present.
  Idempotent — safe to call on every boot. Roughly 200KB total
  on disk and ~tens of milliseconds to render the first time.
  """
  def ensure_rendered! do
    dir = Path.join(:code.priv_dir(:aural), "static/chimes")
    File.mkdir_p!(dir)

    Enum.each(@kinds, fn kind ->
      path = Path.join(dir, "#{kind}.wav")

      unless File.exists?(path) do
        File.write!(path, render_wav(kind))
      end
    end)

    :ok
  end

  @doc "Force-rerender every chime, overwriting existing files. Use during dev when voices change."
  def rerender! do
    dir = Path.join(:code.priv_dir(:aural), "static/chimes")
    File.mkdir_p!(dir)
    Enum.each(@kinds, fn k -> File.write!(Path.join(dir, "#{k}.wav"), render_wav(k)) end)
    :ok
  end

  defp render_wav(kind) do
    n_samples = Signals.chime_lifetime_samples(kind)
    pcm = render_pcm(kind, n_samples)
    wav_header(byte_size(pcm)) <> pcm
  end

  # Build the PCM as an iolist (O(n)) and convert at the end.
  # Direct binary-concat in a fold would be O(n²).
  defp render_pcm(kind, n_samples) do
    sr = @sample_rate

    iolist =
      for n <- 0..(n_samples - 1) do
        x = Signals.chime_sample(kind, n / sr)
        i = x |> max(-1.0) |> min(1.0) |> Kernel.*(32767) |> round()
        <<i::16-little-signed>>
      end

    IO.iodata_to_binary(iolist)
  end

  defp wav_header(pcm_size) do
    sr = @sample_rate
    # mono, 16-bit
    byte_rate = sr * 2
    block_align = 2
    bits = 16
    fmt_size = 16
    pcm_format = 1
    num_channels = 1

    <<
      "RIFF",
      36 + pcm_size::32-little,
      "WAVE",
      "fmt ",
      fmt_size::32-little,
      pcm_format::16-little,
      num_channels::16-little,
      sr::32-little,
      byte_rate::32-little,
      block_align::16-little,
      bits::16-little,
      "data",
      pcm_size::32-little
    >>
  end
end
