defmodule LoopyardWeb.AttachmentController do
  @moduledoc """
  Serves a chat attachment out of the agent's container so the transcript's
  thumbnails are plain `<img src>`.

  Routes:
    * GET /projects/:project_id/workspaces/:workspace_id/attachments/:name — code volume
    * GET /operator/attachments/:name — the operator's workstation `$HOME`

  `name` must be a stored attachment basename (`Attachments.volume_path/1` /
  `container_path/2` reject anything else — no traversal, no dotfiles).

  **What gets rendered inline is decided by the BYTES, not the name.** A file
  that sniffs as png/jpeg/gif/webp is served inline with that type; anything
  else — an uploaded `.html`, an SVG (scripts), a mislabelled file — goes out
  as `application/octet-stream` with `Content-Disposition: attachment`, and
  every response carries `Content-Security-Policy: sandbox`, so nothing an
  uploader controls can ever run on Loopyard's origin. Names are unique per
  upload, so responses are immutable-cacheable, and bytes are cached in
  `Attachments.Cache` (a stopped workspace's thumbnails otherwise spin up a
  throwaway container per request).
  """
  use LoopyardWeb, :controller

  alias Loopyard.Attachments

  def show(conn, %{"workspace_id" => workspace_id, "name" => name}) do
    with {:ok, rel} <- Attachments.volume_path(name),
         volume = Loopyard.Workspace.volume_name_for(workspace_id),
         {:ok, content} <-
           Attachments.Cache.fetch({:volume, volume, name}, fn ->
             reader().read_file(volume, rel)
           end) do
      send_attachment(conn, name, content)
    else
      _ -> not_found(conn)
    end
  end

  @doc "The operator's attachments: read out of its workstation container's $HOME."
  def operator(conn, %{"name" => name}) do
    {:container, container, home} = Loopyard.Operator.attachment_target()

    with {:ok, path} <- Attachments.container_path(home, name),
         {:ok, content} <-
           Attachments.Cache.fetch({:container, container, path}, fn ->
             container_io().read_file(container, path)
           end) do
      send_attachment(conn, name, content)
    else
      _ -> not_found(conn)
    end
  end

  # sobelow_skip ["XSS.ContentType"] — `type` is never caller-supplied: it's one
  # of the fixed image MIMEs `Attachments.sniff_image/1` recognises from the
  # bytes, else application/octet-stream as an attachment; the response is also
  # served under a `sandbox` CSP + nosniff.
  defp send_attachment(conn, name, content) do
    {type, disposition} =
      case Attachments.sniff_image(content) do
        mime when is_binary(mime) -> {mime, "inline"}
        nil -> {"application/octet-stream", "attachment"}
      end

    conn
    |> put_resp_content_type(type, nil)
    |> put_resp_header("content-disposition", ~s(#{disposition}; filename="#{name}"))
    |> put_resp_header("content-security-policy", "sandbox")
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
