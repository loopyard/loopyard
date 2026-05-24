defmodule AuralWeb.StreamController do
  @moduledoc """
  HTTP audio stream + browser-side diag loopback.

  `stream/2` proxies the chunked MP3 bytes coming off a channel's
  PubSub topic to the HTTP response. Many listeners can be on the
  same channel — they all hear the byte-stream from the same ffmpeg
  encoder at the same moment.

  `diag/2` logs error payloads the browser-side hook posts back so
  we can read them without copy-pasting from DevTools.
  """
  use Phoenix.Controller, formats: []
  import Plug.Conn
  require Logger

  alias Aural.Channel

  @doc false
  def diag(conn, payload) do
    Logger.warning("[aural:diag] #{inspect(payload, pretty: true, limit: :infinity)}")
    send_resp(conn, 204, "")
  end

  @doc false
  def stream(conn, %{"channel_id" => channel_id}) do
    conn =
      conn
      |> put_resp_content_type("audio/mpeg")
      |> put_resp_header("cache-control", "no-cache, no-store, must-revalidate")
      |> send_chunked(200)

    # subscribe/1 lazy-starts the channel if it isn't already running
    # — this is also where a stale-but-valid URL respawns transparently.
    Channel.subscribe(channel_id)
    forward_loop(conn)
  end

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
