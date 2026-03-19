defmodule BoomLooperWeb.LaunchController do
  use BoomLooperWeb, :controller

  def launch(conn, %{"secret" => secret, "path" => path}) do
    expected = Application.get_env(:boom_looper, :launch_secret)

    if Plug.Crypto.secure_compare(secret, expected) do
      path = Path.expand(path)

      case BoomLooper.WorkspaceRegistry.add(path) do
        {:ok, workspace} ->
          redirect(conn, to: "/w/#{workspace.id}/new")

        {:error, reason} ->
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(400, "Failed: #{reason}")
      end
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "Invalid secret")
    end
  end

  def launch(conn, %{"secret" => _secret}) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "Missing path parameter. Usage: open \"http://localhost:4000/launch/SECRET?path=$(pwd)\"")
  end
end
