defmodule LoopyardWeb.Live.WorkspaceLive.Attachments do
  @moduledoc """
  The composer's file uploads, LiveView-side: one `allow_upload` named
  `:attachments` that the paperclip (file picker), a paste into the box, and a
  drop anywhere on the chat pane all feed (see the `ChatForm` hook), and the
  consume step that moves the finished uploads into the workspace volume on
  Send (`Loopyard.Attachments.store/2`).

  Consume is all-or-nothing: entries are only marked consumed after EVERY
  file landed in the volume, so a failed copy keeps the whole tray (and the
  typed text — the hook restores it on `ok: false`) for a retry.
  """

  import Phoenix.LiveView,
    only: [allow_upload: 3, cancel_upload: 3, uploaded_entries: 2, consume_uploaded_entries: 3]

  require Logger

  @max_entries 10
  # 25 MB — comfortably a full-res retina screenshot or a fat log; not a video.
  @max_file_size 25 * 1024 * 1024

  def max_entries, do: @max_entries

  @doc "Per-file cap in bytes (`:attachment_max_bytes` app env overrides — tests shrink it)."
  def max_file_size, do: Application.get_env(:loopyard, :attachment_max_bytes, @max_file_size)

  @doc "Declare the upload on mount. `accept: :any` — logs and mockups count too."
  def allow(socket) do
    allow_upload(socket, :attachments,
      accept: :any,
      max_entries: @max_entries,
      max_file_size: max_file_size(),
      auto_upload: true
    )
  end

  def cancel(socket, ref), do: cancel_upload(socket, :attachments, ref)

  @doc """
  True when the tray holds anything SENDABLE — a Send with an empty box is
  still a send. An entry the client refused (too large, too many) shows its
  error in the tray but is never pending: it can't upload, so it must not
  hold a Send hostage.
  """
  def pending?(socket), do: valid_entries(socket) != []

  @doc "The tray's sendable entries (what the chip count and the Send gate see)."
  def valid_entries(socket) do
    case socket.assigns[:uploads] do
      %{attachments: %{entries: entries}} -> Enum.filter(entries, & &1.valid?)
      _ -> []
    end
  end

  @doc """
  Move the finished uploads into the workspace's code volume.

  Returns `{:ok, attachments}` (possibly `[]`) or `{:error, note}` with the
  one line the composer shows under the box.
  """
  @spec consume(Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t(), [Loopyard.Attachments.attachment()]}
          | {:error, String.t()}
  def consume(socket) do
    if socket.assigns[:uploads] do
      # Refused entries (too large / too many) never upload, so they'd sit in
      # `in_progress` forever and turn every Send into "still uploading". Drop
      # them here — their error already showed in the tray — and send the rest.
      socket = drop_invalid(socket)

      case uploaded_entries(socket, :attachments) do
        {[], []} ->
          {:ok, socket, []}

        {_done, [_ | _]} ->
          {:error, "Still uploading your attachment(s) — try Send again in a moment."}

        {_done, []} ->
          # Pass 1 gathers the temp paths WITHOUT consuming (postpone keeps every
          # entry), so a failed copy loses nothing; pass 2 consumes after all
          # copies succeeded.
          uploads =
            consume_uploaded_entries(socket, :attachments, fn %{path: path}, entry ->
              {:postpone,
               %{
                 path: path,
                 client_name: entry.client_name,
                 client_type: entry.client_type,
                 client_size: entry.client_size
               }}
            end)

          case safe_store(target(socket), uploads) do
            {:ok, atts} ->
              consume_uploaded_entries(socket, :attachments, fn _, _ -> {:ok, :consumed} end)
              {:ok, socket, atts}

            {:error, reason} ->
              Logger.warning(
                "[Attachments] store failed for #{inspect(target(socket))}: #{inspect(reason)}"
              )

              {:error,
               "Couldn't save the attachment(s) into the agent's container — " <>
                 "make sure it's running, then Send again. Your text and files are kept."}
          end
      end
    else
      {:ok, socket, []}
    end
  end

  defp drop_invalid(socket) do
    socket.assigns.uploads.attachments.entries
    |> Enum.reject(& &1.valid?)
    |> Enum.reduce(socket, fn entry, sock -> cancel_upload(sock, :attachments, entry.ref) end)
  end

  # The Docker boundary: a raise here must not crash the LiveView (that drops
  # the tray AND the typed text) — it's the same "kept for retry" outcome as
  # an {:error, _}.
  # Where this composer's files go: an explicit `:attachment_target` assign
  # (the operator sets one), else the workspace the LiveView is on.
  defp target(socket) do
    socket.assigns[:attachment_target] || {:workspace, socket.assigns.workspace.id}
  end

  defp safe_store(target, uploads) do
    Loopyard.Attachments.store(target, uploads)
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  @doc "Copy for an upload error atom, shown on the tray."
  def error_text(:too_large), do: "Too large — up to 25 MB per file."
  def error_text(:too_many_files), do: "Up to #{@max_entries} files per message."
  def error_text(:not_accepted), do: "That file type isn't accepted."
  def error_text(:external_client_failure), do: "The upload was interrupted — add it again."
  def error_text(other), do: "Upload failed (#{inspect(other)})."
end
