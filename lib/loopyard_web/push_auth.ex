defmodule LoopyardWeb.PushAuth do
  @moduledoc """
  Shared auth for the "push a credential into the workstation from your Mac"
  endpoints (`EnvController`, `FileController`).

  A **local** request (loopback peer, no proxy/forwarding headers) needs no
  token — a curl on this machine is already trusted. A **tunnel/remote** request
  must carry `Loopyard.PushToken` (Bearer header or `?token=`), since the routes
  are reachable over the public quick-tunnel; cloudflared connects from loopback
  but adds X-Forwarded-For / Cf-Connecting-Ip, so the no-token path stays local.
  """
  import Plug.Conn

  alias Loopyard.PushToken

  @spec authorized?(Plug.Conn.t()) :: boolean()
  def authorized?(conn) do
    local?(conn) or PushToken.valid?(supplied_token(conn))
  end

  defp local?(conn) do
    loopback?(conn.remote_ip) and
      get_req_header(conn, "x-forwarded-for") == [] and
      get_req_header(conn, "cf-connecting-ip") == [] and
      get_req_header(conn, "forwarded") == []
  end

  defp loopback?({127, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  defp supplied_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> t | _] -> String.trim(t)
      _ -> conn.params["token"]
    end
  end
end
