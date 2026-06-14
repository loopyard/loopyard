defmodule LoopyardWeb.EnvController do
  @moduledoc """
  Receive endpoint for pushing a workstation env var in from outside Loopyard —
  the "transfer credentials from your Mac into the Docker workstation" path:

      gh auth token | curl -T - http://localhost:4000/workstation/env/GITHUB_TOKEN

  `-T -` PUTs stdin as the raw body (no `-X`, no `-d`, no content-type). Stores
  the value via `Loopyard.Workstation.Env` (injected as `-e` into the console +
  every agent at boot — Restart to apply).

  Auth: a **local** request (loopback peer, no proxy/forwarding headers) needs
  no token — a curl on this machine is already trusted. A **tunnel/remote**
  request must carry the `Loopyard.PushToken` (Bearer header or `?token=`), since
  the route is reachable over the public quick-tunnel.
  """
  use LoopyardWeb, :controller

  alias Loopyard.PushToken
  alias Loopyard.Workstation.Env

  def put(conn, %{"key" => key}) do
    if authorized?(conn) do
      {:ok, raw, conn} = read_body(conn)

      case String.trim(raw) do
        "" ->
          conn |> put_status(:bad_request) |> json(%{error: "empty value"})

        value ->
          case Env.put(key, value) do
            :ok -> send_resp(conn, :no_content, "")
            {:error, :invalid_key} -> conn |> put_status(:bad_request) |> json(%{error: "invalid key"})
          end
      end
    else
      conn |> put_status(:forbidden) |> json(%{error: "bad or missing push token"})
    end
  end

  defp authorized?(conn) do
    local?(conn) or PushToken.valid?(supplied_token(conn))
  end

  # A genuine local request: loopback peer AND no proxy/forwarding headers. The
  # tunnel (cloudflared) connects FROM loopback but adds X-Forwarded-For /
  # Cf-Connecting-Ip, so this stays false for tunneled traffic — which is what
  # keeps the no-token path local-only.
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
