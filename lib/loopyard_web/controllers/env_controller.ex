defmodule LoopyardWeb.EnvController do
  @moduledoc """
  Receive endpoint for pushing a workstation env var in from outside Loopyard —
  the "transfer credentials from your Mac into the Docker workstation" path:

      gh auth token | curl -X PUT \\
        -H "Authorization: Bearer <push-token>" \\
        -H "Content-Type: text/plain" \\
        --data-binary @- \\
        https://<loopyard>/env/GITHUB_TOKEN

  Stores the value via `Loopyard.Workstation.Env` (injected as `-e` into the
  console + every agent at boot — Restart to apply). Token-gated (see
  `Loopyard.PushToken`) since the route is reachable over the public tunnel; the
  body is the raw token value (`text/plain`, passes Plug.Parsers' `*/*`).
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
    token =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> t | _] -> String.trim(t)
        _ -> conn.params["token"]
      end

    PushToken.valid?(token)
  end
end
