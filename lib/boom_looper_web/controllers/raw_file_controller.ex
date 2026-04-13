defmodule BoomLooperWeb.RawFileController do
  @moduledoc """
  Serves raw file content from a Docker volume. Content-type is text/plain
  with disposition: inline so the browser displays it directly.

  Route: GET /raw/:volume_name/*path
  """
  use BoomLooperWeb, :controller

  def show(conn, %{"volume_name" => volume_name, "path" => path_parts}) do
    path = Path.join(path_parts)

    case BoomLooper.VolumeIO.read_file(volume_name, path) do
      {:ok, content} ->
        conn
        |> put_resp_content_type("text/plain; charset=utf-8")
        |> put_resp_header("content-disposition", "inline")
        |> send_resp(200, content)

      {:error, _} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "File not found: #{path}")
    end
  end
end
