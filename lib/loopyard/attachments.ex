defmodule Loopyard.Attachments do
  @moduledoc """
  Files a human attaches to a chat message (screenshots, logs, mockups) so the
  agent can look at them.

  The design is deliberately harness-agnostic and string-shaped: an attachment
  is a FILE IN THE CODE VOLUME (`/workspace/.loopyard/uploads/<name>`) plus ONE
  marker line appended to the message text. Nothing above the message string
  changes — the pending queue, edit-in-place, retry, the ETF log, batch
  framing, `recall_conversation` all carry attachments for free — and any
  harness that can read a file from `/workspace` (Claude's native `Read`
  renders images; Codex has `view_image`) can look at it. The ACP prompt stays
  text-only; sending an image content block instead is a fast path for later,
  not the mechanism.

  Three jobs:

    * `store/2` — copy uploaded temp files into the workspace volume, returning
      `t:attachment/0` descriptors. Writes go through the configured
      `:attachment_writer` (default `Loopyard.VolumeIO`) so tests never touch
      Docker.
    * `annotate/2` — append the marker lines to the user's text. This IS the
      prompt the harness sees and the content the transcript persists.
    * `parse/1` — split a persisted message back into `{clean_text,
      attachments}` so the transcript renders thumbnails instead of marker
      lines.

  The upload dir carries a self-ignoring `.gitignore` (`*`) so screenshots can
  never ride into a commit.
  """

  alias Loopyard.Workspace

  @dir "/workspace/.loopyard/uploads"
  @rel_dir ".loopyard/uploads"
  @marker "📎 Attached: "
  @hint " — open the file to view it"

  # One marker line per file, parseable back out of a persisted message.
  #   📎 Attached: /workspace/.loopyard/uploads/20260901T120000-ab12-shot.png (image/png, 84213 bytes) — open the file to view it
  @line_re ~r/^📎 Attached: (?<path>\S+) \((?<mime>[^,()\s]+), (?<size>\d+) bytes\)(?: — [^\n]*)?$/

  # Stored names are restricted to this alphabet — it's what makes the marker
  # line unambiguous (no spaces in the path) and the URL param safe.
  @safe_name ~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/
  @max_name 60

  @type attachment :: %{
          path: String.t(),
          name: String.t(),
          mime: String.t(),
          size: non_neg_integer()
        }

  @type upload :: %{
          required(:path) => Path.t(),
          required(:client_name) => String.t(),
          optional(:client_type) => String.t() | nil,
          optional(:client_size) => non_neg_integer() | nil
        }

  @doc "Absolute in-container directory uploads land in."
  def dir, do: @dir

  @doc """
  Copy uploaded files into the workspace's code volume.

  `uploads` are LiveView upload entries (`path` is the host temp file). Returns
  `{:ok, [attachment]}` in the given order, or `{:error, reason}` on the first
  failed copy (earlier copies are left in place — they're harmless and the
  caller keeps the entries to retry).
  """
  @spec store(String.t(), [upload()]) :: {:ok, [attachment()]} | {:error, term()}
  def store(workspace_id, uploads) when is_list(uploads) do
    volume = Workspace.volume_name_for(workspace_id)

    with :ok <- ensure_gitignore(volume) do
      Enum.reduce_while(uploads, {:ok, []}, fn upload, {:ok, acc} ->
        name = stored_name(upload.client_name)
        dest = Path.join(@dir, name)

        case writer().copy_in(volume, upload.path, dest) do
          :ok ->
            att = %{
              path: dest,
              name: name,
              mime: mime_for(upload),
              size: upload[:client_size] || file_size(upload.path)
            }

            {:cont, {:ok, [att | acc]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, atts} -> {:ok, Enum.reverse(atts)}
        error -> error
      end
    end
  end

  @doc """
  The message text the harness sees: the human's words, then one marker line
  per attachment. With no attachments the text is returned untouched.
  """
  @spec annotate(String.t(), [attachment()]) :: String.t()
  def annotate(text, []), do: text

  def annotate(text, atts) when is_list(atts) do
    lines = Enum.map_join(atts, "\n", &marker_line/1)

    case String.trim(text) do
      "" -> lines
      body -> body <> "\n\n" <> lines
    end
  end

  @doc """
  Split a persisted message back into the human's text and its attachments.
  A message with no marker lines comes back as `{text, []}` unchanged.
  """
  @spec parse(String.t() | nil) :: {String.t(), [attachment()]}
  def parse(nil), do: {"", []}

  def parse(text) when is_binary(text) do
    if String.contains?(text, @marker) do
      {atts, kept} =
        text
        |> String.split("\n")
        |> Enum.reduce({[], []}, fn line, {atts, kept} ->
          case Regex.named_captures(@line_re, line) do
            %{"path" => path, "mime" => mime, "size" => size} ->
              att = %{
                path: path,
                name: Path.basename(path),
                mime: mime,
                size: String.to_integer(size)
              }

              {[att | atts], kept}

            nil ->
              {atts, [line | kept]}
          end
        end)

      {kept |> Enum.reverse() |> Enum.join("\n") |> String.trim_trailing(), Enum.reverse(atts)}
    else
      {text, []}
    end
  end

  @doc "True when the attachment is a browser-renderable image."
  def image?(%{mime: "image/" <> sub}), do: sub not in ["svg+xml"]
  def image?(_), do: false

  @doc """
  The URL the browser fetches an attachment from — a resource path under its
  project + workspace (`AttachmentController`). `nil` when the workspace can't
  be resolved (the file still shows as a name).
  """
  @spec url(String.t() | nil, attachment() | String.t()) :: String.t() | nil
  def url(workspace_id, %{name: name}), do: url(workspace_id, name)

  def url(workspace_id, name) when is_binary(workspace_id) and is_binary(name) do
    case Loopyard.ProjectRegistry.get_workspace(workspace_id) do
      %{project_id: pid} when is_binary(pid) ->
        "/projects/#{pid}/workspaces/#{workspace_id}/attachments/#{name}"

      _ ->
        nil
    end
  end

  def url(_, _), do: nil

  @doc "Volume-relative path of a stored attachment by name, or `:error` for an unsafe name."
  @spec volume_path(String.t()) :: {:ok, String.t()} | :error
  def volume_path(name) when is_binary(name) do
    if safe_name?(name), do: {:ok, Path.join(@rel_dir, name)}, else: :error
  end

  @doc false
  def safe_name?(name), do: Regex.match?(@safe_name, name) and name != "." and name != ".."

  @doc """
  The stored filename for an upload: a timestamp + short random prefix (unique,
  sortable) and the client's name reduced to a safe alphabet, extension kept.
  """
  @spec stored_name(String.t()) :: String.t()
  def stored_name(client_name) do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%S")
    rand = :crypto.strong_rand_bytes(2) |> Base.encode16(case: :lower)
    "#{stamp}-#{rand}-#{sanitize(client_name)}"
  end

  @doc "Human-readable size for chips (`84 KB`, `1.2 MB`)."
  def human_size(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"
  def human_size(bytes) when is_integer(bytes) and bytes < 1_048_576, do: "#{div(bytes, 1024)} KB"
  def human_size(bytes) when is_integer(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  def human_size(_), do: ""

  # --- private ---

  defp marker_line(%{path: path, mime: mime, size: size}) do
    "#{@marker}#{path} (#{mime}, #{size} bytes)#{@hint}"
  end

  defp sanitize(client_name) do
    base = Path.basename(client_name || "")
    ext = Path.extname(base) |> String.downcase() |> String.replace(~r/[^a-z0-9.]/, "")
    stem = Path.rootname(base)

    stem =
      stem
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
      |> String.trim("-")
      |> String.trim(".")
      |> String.slice(0, @max_name)

    stem = if stem == "", do: "file", else: stem
    stem <> ext
  end

  defp mime_for(%{client_type: type}) when is_binary(type) and type != "", do: type
  defp mime_for(%{client_name: name}), do: MIME.from_path(name)

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: s}} -> s
      _ -> 0
    end
  end

  # `*` inside the dir ignores everything in it (including itself), so a
  # repo whose `.gitignore` doesn't cover `.loopyard/` never sees screenshots
  # as untracked files an agent might `git add -A`.
  defp ensure_gitignore(volume) do
    case writer().write_file(volume, Path.join(@rel_dir, ".gitignore"), "*\n") do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp writer, do: Application.get_env(:loopyard, :attachment_writer, Loopyard.VolumeIO)
end
