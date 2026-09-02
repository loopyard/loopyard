defmodule LoopyardWeb.AttachmentController do
  @moduledoc """
  Serves a chat attachment out of the workspace's code volume with its real
  content type, so the transcript's thumbnails are plain `<img src>`.

  Route: GET /projects/:project_id/workspaces/:workspace_id/attachments/:name

  `name` must be a stored attachment basename (`Attachments.volume_path/1`
  rejects anything else — no traversal, no dotfiles). Names are unique per
  upload (timestamp + random prefix), so the response is immutable-cacheable.
  Reads go through the configured `:volume_reader` (default `VolumeIO`), the
  same seam `ClaudeContext` uses, so tests never touch Docker.
  """
  use LoopyardWeb, :controller

  alias Loopyard.Attachments

  def show(conn, %{"workspace_id" => workspace_id, "name" => name}) do
    with {:ok, rel} <- Attachments.volume_path(name),
         volume = Loopyard.Workspace.volume_name_for(workspace_id),
         {:ok, content} <- reader().read_file(volume, rel) do
      conn
      |> put_resp_content_type(MIME.from_path(name), nil)
      |> put_resp_header("content-disposition", ~s(inline; filename="#{name}"))
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_resp(200, content)
    else
      _ ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Attachment not found")
    end
  end

  defp reader, do: Application.get_env(:loopyard, :volume_reader, Loopyard.VolumeIO)
end
