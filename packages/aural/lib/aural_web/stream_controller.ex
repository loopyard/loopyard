defmodule AuralWeb.StreamController do
  @moduledoc """
  HTTP audio stream proxy. Subscribes the HTTP response to the
  shared `Aural.Channel`'s PubSub topic and forwards
  every encoded MP3 chunk to the browser via chunked transfer
  encoding.

  Multiple listeners can subscribe — they all hear the same byte
  stream coming off the channel's single ffmpeg encoder. A chime
  fired on the channel reaches every connected listener at the
  same moment in the audio.

  The diag endpoint is unchanged — browsers POST audio events
  here so we can read them in the server log.
  """
  use Phoenix.Controller, formats: []
  import Plug.Conn
  require Logger

  alias Aural.Channel

  @doc """
  Diagnostic loopback. Browser POSTs error/event payloads here;
  we log them so we can read them without copy-pasting from
  DevTools.
  """
  def diag(conn, payload) do
    Logger.warning("[aural:diag] #{inspect(payload, pretty: true, limit: :infinity)}")
    send_resp(conn, 204, "")
  end

  def stream(conn, _params) do
    conn =
      conn
      |> put_resp_content_type("audio/mpeg")
      |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
      |> send_chunked(200)

    Channel.subscribe()
    forward_loop(conn)
  end

  # Receive {:mp3, bytes} broadcasts from the channel and chunk them
  # out to the HTTP client. Bails when the client disconnects
  # (Plug.Conn.chunk returns {:error, _}) or when nothing arrives
  # for 60s (channel is wedged, give up).
  defp forward_loop(conn) do
    receive do
      {:mp3, bytes} ->
        case Plug.Conn.chunk(conn, bytes) do
          {:ok, conn} -> forward_loop(conn)
          {:error, _} -> conn
        end
    after
      60_000 -> conn
    end
  end
end
