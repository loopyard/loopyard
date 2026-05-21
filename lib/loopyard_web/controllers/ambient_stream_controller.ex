defmodule LoopyardWeb.AmbientStreamController do
  @moduledoc """
  HTTP audio stream for the ambient soundtrack.

  Pipeline: Synth → raw PCM → ffmpeg (encode Opus into Ogg) →
  HTTP chunked response → browser `<audio>` element.

  Opus is the right codec for this:
    - Best quality per bit for music (96kbps Opus ≈ 192kbps MP3)
    - ~20ms encoding latency vs MP3's ~200ms — first audio frame
      reaches the browser faster, helps avoid Safari's
      "loading too slow → abort" behavior
    - Designed for streaming (Skype/Discord/WebRTC use it)
    - Native support in every modern browser (Safari 14+,
      everything else for years)

  Each HTTP listener has its own ffmpeg subprocess and timeline.
  ffmpeg is ~10MB RAM per process — fine for Loopyard's scale.
  """
  use LoopyardWeb, :controller
  require Logger

  alias Loopyard.Ambient.Synth

  @doc """
  Diagnostic loopback. Browser POSTs error/event payloads here;
  we log them to the server so the human debugging can read them
  without copy-pasting from DevTools.
  """
  def diag(conn, payload) do
    Logger.warning("[ambient:diag] #{inspect(payload, pretty: true, limit: :infinity)}")
    send_resp(conn, 204, "")
  end

  # Produce PCM in 100ms slices. We do NOT pace with Process.sleep —
  # let TCP backpressure on the browser's HTTP buffer pace the chain.
  # The browser fills its internal buffer (~30s for HTMLMediaElement),
  # then network writes block until it needs more. This eliminates
  # the every-N-seconds buffer-underrun stalls you get when shipping
  # at exactly real-time rate.
  @chunk_samples 4_800

  def stream(conn, params) do
    track = resolve_track(params)

    conn =
      conn
      |> put_resp_content_type("audio/ogg")
      |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
      |> send_chunked(200)

    port = open_ffmpeg(Synth.sample_rate())

    # Producer task: render PCM and pipe to ffmpeg stdin. Linked to
    # the controller process, so client disconnect → controller
    # exit → task killed → port closed → ffmpeg exits.
    producer =
      Task.async(fn ->
        try do
          pcm_loop(port, track, 0)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end)

    conn = read_mp3_loop(conn, port)

    Task.shutdown(producer, :brutal_kill)
    safe_close(port)
    conn
  end

  defp resolve_track(%{"track" => name}) do
    case Synth.resolve(name) do
      nil -> :serene
      _module -> String.to_existing_atom(name)
    end
  rescue
    ArgumentError -> :serene
  end

  defp resolve_track(_), do: :serene

  defp pcm_loop(port, track, t) do
    pcm = Synth.render_chunk(track, t, @chunk_samples)
    # Port.command blocks when the OS pipe to ffmpeg is full, which
    # in turn happens when ffmpeg's encode + the browser-side HTTP
    # buffer is full. No manual sleep needed — the chain paces itself.
    Port.command(port, pcm)
    pcm_loop(port, track, t + @chunk_samples)
  end

  defp read_mp3_loop(conn, port) do
    receive do
      {^port, {:data, mp3}} ->
        case Plug.Conn.chunk(conn, mp3) do
          {:ok, conn} -> read_mp3_loop(conn, port)
          {:error, _} -> conn
        end

      {^port, {:exit_status, _}} ->
        conn
    after
      10_000 ->
        # ffmpeg gone quiet for 10s — bail out.
        conn
    end
  end

  defp open_ffmpeg(sample_rate) do
    ffmpeg = System.find_executable("ffmpeg") || raise "ffmpeg not on PATH"

    Port.open(
      {:spawn_executable, ffmpeg},
      [
        :binary,
        :exit_status,
        :use_stdio,
        args: [
          "-hide_banner",
          "-loglevel",
          "error",
          # Input: raw signed 16-bit little-endian mono PCM from stdin
          "-f",
          "s16le",
          "-ar",
          to_string(sample_rate),
          "-ac",
          "1",
          "-i",
          "pipe:0",
          # Output: libopus in Ogg container, 96kbps. -application
          # audio tunes the codec for music (vs voip which optimizes
          # for speech intelligibility). -frame_duration 20 keeps
          # packets small for streaming. -flush_packets so chunks
          # start arriving fast.
          "-c:a",
          "libopus",
          "-b:a",
          "96k",
          "-application",
          "audio",
          "-frame_duration",
          "20",
          "-f",
          "ogg",
          "-flush_packets",
          "1",
          "pipe:1"
        ]
      ]
    )
  end

  defp safe_close(port) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
  end
end
