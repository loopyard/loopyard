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

  alias Loopyard.Workstation.Env
  alias LoopyardWeb.PushAuth

  def put(conn, %{"key" => key}) do
    if PushAuth.authorized?(conn) do
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
end
