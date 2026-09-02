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
      send_attachment(conn, name, content)
    else
      _ -> not_found(conn)
    end
  end

  @doc "The operator's attachments: read out of its workstation container's $HOME."
  def operator(conn, %{"name" => name}) do
    {:container, container, home} = Loopyard.Operator.attachment_target()

    with {:ok, path} <- Attachments.container_path(home, name),
         {:ok, content} <- container_io().read_file(container, path) do
      send_attachment(conn, name, content)
    else
      _ -> not_found(conn)
    end
  end

  defp send_attachment(conn, name, content) do
    conn
    |> put_resp_content_type(MIME.from_path(name), nil)
    |> put_resp_header("content-disposition", ~s(inline; filename="#{name}"))
    |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(200, content)
  end

  defp not_found(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Attachment not found")
  end

  defp reader, do: Application.get_env(:loopyard, :volume_reader, Loopyard.VolumeIO)
  defp container_io, do: Application.get_env(:loopyard, :container_io, Loopyard.ContainerIO)
end
