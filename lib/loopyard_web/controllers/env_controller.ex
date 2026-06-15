defmodule LoopyardWeb.EnvController do
  @moduledoc """
  Receive endpoint for pushing an env var into a *named* workstation from outside
  Loopyard — the "transfer credentials from your Mac into the Docker workstation"
  path. The workstation id is in the URL (the curl names which identity):

      gh auth token | curl -T - http://localhost:4000/workstations/brad/env/GITHUB_TOKEN

  `-T -` PUTs stdin as the raw body (no `-X`, no `-d`, no content-type). Stores
  the value via `Loopyard.Workstation.Env` (injected as `-e` into the console +
  every agent at boot — Restart to apply).

  Auth: a **local** request (loopback peer, no proxy/forwarding headers) needs
  no token — a curl on this machine is already trusted. A **tunnel/remote**
  request must carry the `Loopyard.PushToken` (Bearer header or `?token=`), since
  the route is reachable over the public quick-tunnel.
  """
  use LoopyardWeb, :controller

  alias Loopyard.Workstation
  alias Loopyard.Workstation.Env
  alias LoopyardWeb.PushAuth

  def put(conn, %{"id" => ws, "key" => key}) do
    cond do
      not PushAuth.authorized?(conn) ->
        conn |> put_status(:forbidden) |> json(%{error: "bad or missing push token"})

      not Workstation.exists?(ws) ->
        conn |> put_status(:not_found) |> json(%{error: "no such workstation: #{ws}"})

      true ->
        do_put(conn, ws, key)
    end
  end

  defp do_put(conn, ws, key) do
    {:ok, raw, conn} = read_body(conn)

    case String.trim(raw) do
      "" ->
        conn |> put_status(:bad_request) |> json(%{error: "empty value"})

      value ->
        case Env.put(key, value, ws) do
          :ok -> send_resp(conn, :no_content, "")
          {:error, :invalid_key} -> conn |> put_status(:bad_request) |> json(%{error: "invalid key"})
        end
    end
  end
end
