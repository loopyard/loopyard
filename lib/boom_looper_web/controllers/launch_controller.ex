defmodule BoomLooperWeb.LaunchController do
  use BoomLooperWeb, :controller

  def launch(conn, %{"secret" => secret, "path" => path}) do
    expected = Application.get_env(:boom_looper, :launch_secret)

    if Plug.Crypto.secure_compare(secret, expected) do
      path = Path.expand(path)

      case BoomLooper.ProjectRegistry.add(path) do
        {:ok, project, branch} ->
          # If workspace config exists, go straight to branch view
          # Otherwise redirect to new agent (will auto-spawn Setup)
          dest = case BoomLooper.Workspace.load(project.path) do
            {:ok, _} -> "/p/#{project.id}/b/#{branch.id}"
            _ -> "/p/#{project.id}/b/#{branch.id}/new"
          end
          redirect(conn, to: dest)

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
