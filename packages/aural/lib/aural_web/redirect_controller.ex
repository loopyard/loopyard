defmodule AuralWeb.RedirectController do
  @moduledoc """
  Bounces a bare `/aural` request to `/aural/<new_channel_id>`.

  Each fresh URL is sharable: anyone who opens it joins the same
  channel as everyone else with that URL. Closing it for everyone
  → after the configured idle timeout, the channel self-terminates;
  reopening the URL respawns a new channel under the same ID.
  """
  use Phoenix.Controller, formats: []
  import Plug.Conn

  def new_channel(conn, _params) do
    id = Aural.Channel.new_id()
    # The host's router mounts our LiveView at `/aural/:channel_id`,
    # so the redirect target sits one path segment above this scope.
    base = request_path_base(conn)
    target = base <> "/" <> id

    conn
    |> put_resp_header("location", target)
    |> send_resp(302, "")
  end

  # Strip the trailing "/" if the request was the bare "/aural".
  # request_path is whatever the host mounted us under.
  defp request_path_base(conn) do
    case conn.request_path do
      "/" <> _ = path -> String.trim_trailing(path, "/")
      path -> path
    end
  end
end
