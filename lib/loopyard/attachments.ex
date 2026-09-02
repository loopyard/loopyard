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

  **Seeing the pixels.** The marker line is the durable contract, but a harness
  that can take images in its prompt (ACP `promptCapabilities.image` — the
  Claude adapter does) gets them INLINE too: `prompt_blocks/2` turns the text
  into `[text | image blocks]`, reading each image out of the volume, so the
  model looks at the screenshot in the same turn without a Read round-trip.
  The text (and its marker lines) always goes; images ride along when they
  can. Non-images, oversize images, and unreadable files simply stay
  path-only.
  """

  alias Loopyard.Workspace

  @dir "/workspace/.loopyard/uploads"
  @rel_dir ".loopyard/uploads"

  @typedoc """
  Where a chat's attachments live. A workspace agent's go into its code volume
  (`/workspace/.loopyard/uploads`); a workspace-less agent (the operator) keeps
  them in its own container under `<home>/.loopyard/uploads`.
  """
  @type target :: {:workspace, String.t()} | {:container, String.t(), String.t()}
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

  # Largest image sent inline as a prompt block. Claude's API caps a single
  # image at 5 MB; anything bigger stays path-only (the agent can still Read
  # it — Claude Code downscales on read).
  @max_inline_bytes 5 * 1024 * 1024
  # Total inline image bytes per prompt. Ten 5 MB screenshots would be a
  # ~67 MB JSON-RPC frame over the adapter's stdio; past this, images stay
  # path-only for that turn.
  @max_inline_total 20 * 1024 * 1024
  # The image formats the model takes inline (and every browser renders).
  # Anything else — SVG, TIFF, BMP, HEIC that couldn't be converted — is
  # path-only: the agent can still Read it.
  @inline_mimes ~w(image/png image/jpeg image/gif image/webp)

  @doc """
  What the bytes actually are, for the formats we inline — by magic number.
  The browser's declared type is a claim (a renamed file, a HEIC labelled
  png, a zero-byte file); the API rejects a mislabelled image and the whole
  turn fails with it, so nothing is inlined on the label alone.
  """
  @spec sniff_image(binary()) :: String.t() | nil
  def sniff_image(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: "image/png"
  def sniff_image(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  def sniff_image(<<"GIF87a", _::binary>>), do: "image/gif"
  def sniff_image(<<"GIF89a", _::binary>>), do: "image/gif"
  def sniff_image(<<"RIFF", _::32, "WEBP", _::binary>>), do: "image/webp"
  def sniff_image(_), do: nil

  @doc "HEIC/HEIF (an iPhone photo) by its ISO-BMFF `ftyp` brand."
  @spec heic?(binary()) :: boolean()
  def heic?(<<_::32, "ftyp", brand::binary-size(4), _::binary>>),
    do: brand in ~w(heic heix hevc hevx heim heis mif1 msf1)

  def heic?(_), do: false

  @doc "Formats sent inline as prompt image blocks."
  def inline_mimes, do: @inline_mimes

  @doc "Absolute in-container directory uploads land in."
  def dir, do: @dir

  @doc "The uploads directory for a target."
  @spec dir(target()) :: String.t()
  def dir({:workspace, _}), do: @dir
  def dir({:container, _container, home}), do: Path.join(home, @rel_dir)

  @doc "Absolute path of a stored attachment under a container target, or `:error` for an unsafe name."
  @spec container_path(String.t(), String.t()) :: {:ok, String.t()} | :error
  def container_path(home, name) when is_binary(home) and is_binary(name) do
    if safe_name?(name), do: {:ok, Path.join([home, @rel_dir, name])}, else: :error
  end

  @doc """
  ACP prompt content blocks for a message: the text block (verbatim, marker
  lines included — the path is still useful to the agent), then one
  `%{"type" => "image", "data" => base64, "mimeType" => mime}` block per
  inline-able image attachment read from `volume`.

  `ctx` carries `:volume` (the code volume the paths live in) and `:image?`
  (whether the harness accepts image blocks). With `image?: false` or no
  volume the result is the lone text block — exactly what a text-only
  harness sends today.
  """
  @spec prompt_blocks(String.t(), %{
          optional(:volume) => String.t() | nil,
          optional(:container) => String.t() | nil,
          optional(:cwd) => String.t() | nil,
          optional(:image?) => boolean()
        }) :: [map()]
  def prompt_blocks(text, ctx) when is_binary(text) do
    text_block = %{"type" => "text", "text" => text}

    # Read via the code volume when the session has one (workspace agents),
    # else straight out of the session's container (the operator's $HOME).
    read =
      cond do
        ctx[:image?] != true -> nil
        is_binary(ctx[:volume]) -> &reader().read_file(ctx[:volume], &1)
        is_binary(ctx[:container]) -> &container_io().read_file(ctx[:container], &1)
        true -> nil
      end

    if read do
      # Only files IN the session's uploads dir are ever read for inlining. A
      # marker line is just text — anyone can type one — so a path outside
      # `<cwd>/.loopyard/uploads` (or a name that isn't a stored name) is
      # left alone. This is the confinement; the reader has none of its own.
      uploads_dir = Path.join(ctx[:cwd] || "/workspace", @rel_dir)

      {_body, atts} = parse(text)

      {blocks, _total} =
        atts
        |> Enum.filter(&(Path.dirname(&1.path) == uploads_dir and safe_name?(&1.name)))
        |> Enum.reduce({[], 0}, fn att, {blocks, total} ->
          case image_block(read, att, total) do
            {block, bytes} -> {[block | blocks], total + bytes}
            nil -> {blocks, total}
          end
        end)

      [text_block | Enum.reverse(blocks)]
    else
      [text_block]
    end
  end

  # One inline image block, or nil when the file is not an image we inline
  # (by its BYTES, not its label), is over the per-image cap, would push the
  # prompt over the total budget, or can't be read. Returns the block with
  # its byte size so the caller can keep the running total.
  defp image_block(read, %{size: size} = att, total) do
    with true <- image?(att) and size <= @max_inline_bytes,
         true <- total + size <= @max_inline_total,
         {:ok, bytes} when byte_size(bytes) <= @max_inline_bytes <- read.(att.path),
         mime when is_binary(mime) <- sniff_image(bytes),
         true <- mime in @inline_mimes do
      {%{"type" => "image", "data" => Base.encode64(bytes), "mimeType" => mime}, byte_size(bytes)}
    else
      _ -> nil
    end
  end

  defp reader, do: Application.get_env(:loopyard, :volume_reader, Loopyard.VolumeIO)

  @doc """
  Copy uploaded files into the workspace's code volume.

  `uploads` are LiveView upload entries (`path` is the host temp file). Returns
  `{:ok, [attachment]}` in the given order, or `{:error, reason}` on the first
  failed copy (earlier copies are left in place — they're harmless and the
  caller keeps the entries to retry).
  """
  @spec store(target() | String.t(), [upload()]) :: {:ok, [attachment()]} | {:error, term()}
  def store(workspace_id, uploads) when is_binary(workspace_id),
    do: store({:workspace, workspace_id}, uploads)

  def store(target, uploads) when is_list(uploads) do
    {io, handle} = io_for(target)
    dir = dir(target)

    with :ok <- ensure_gitignore(io, handle, dir) do
      Enum.reduce_while(uploads, {:ok, []}, fn upload, {:ok, acc} ->
        # Sniff first: the stored type is what the bytes are, and an iPhone
        # HEIC becomes a JPEG the model (and the browser) can actually see.
        {upload, mime, converted?} = normalize(upload)
        name = stored_name(upload.client_name)
        dest = Path.join(dir, name)
        size = file_size(upload.path, upload)
        result = io.copy_in(handle, upload.path, dest)
        if converted?, do: File.rm(upload.path)

        case result do
          :ok ->
            att = %{path: dest, name: name, mime: mime, size: size}
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

  # No workspace = the operator (the one workspace-less agent).
  def url(nil, name) when is_binary(name), do: "/operator/attachments/#{name}"
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

  @doc """
  The name a human sees: the stored name minus the `<stamp>-<rand>-` uniqueness
  prefix (`20260902T061913-9608-riddle.png` → `riddle.png`).
  """
  @spec display_name(attachment() | String.t()) :: String.t()
  def display_name(%{name: name}), do: display_name(name)

  def display_name(name) when is_binary(name),
    do: Regex.replace(~r/^\d{8}T\d{6}-[0-9a-f]{4}-/, name, "")

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

  # The upload as stored: `{upload, mime, converted?}`. Images are typed by
  # their bytes; a HEIC is converted to JPEG (macOS `sips`) into a temp file
  # the caller removes; everything else keeps the declared/extension type.
  defp normalize(upload) do
    head = read_head(upload.path)

    cond do
      mime = sniff_image(head) ->
        {upload, mime, false}

      heic?(head) ->
        case convert_heic(upload.path) do
          {:ok, jpg} ->
            {%{upload | path: jpg, client_name: Path.rootname(upload.client_name) <> ".jpg"},
             "image/jpeg", true}

          :error ->
            {upload, mime_for(upload), false}
        end

      true ->
        # Labelled an image (a browser types by extension) but the bytes say
        # otherwise: store it as opaque data so nothing ever renders it as one.
        mime = mime_for(upload)
        mime = if String.starts_with?(mime, "image/"), do: "application/octet-stream", else: mime
        {upload, mime, false}
    end
  end

  defp read_head(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        head = IO.binread(io, 32)
        File.close(io)
        if is_binary(head), do: head, else: ""

      _ ->
        ""
    end
  end

  defp convert_heic(path) do
    out = Path.join(System.tmp_dir!(), "loopyard-heic-#{System.unique_integer([:positive])}.jpg")

    with sips when is_binary(sips) <- System.find_executable("sips"),
         {_, 0} <-
           System.cmd(sips, ["-s", "format", "jpeg", path, "--out", out], stderr_to_stdout: true),
         true <- File.regular?(out) do
      {:ok, out}
    else
      _ ->
        File.rm(out)
        :error
    end
  end

  defp mime_for(%{client_type: type}) when is_binary(type) and type != "", do: type
  defp mime_for(%{client_name: name}), do: MIME.from_path(name)

  # The stored file's size: measured when we can (a converted HEIC is a new
  # file), the client's figure only as a fallback.
  defp file_size(path, upload) do
    case File.stat(path) do
      {:ok, %{size: s}} -> s
      _ -> upload[:client_size] || 0
    end
  end

  # `*` inside the dir ignores everything in it (including itself), so a
  # repo whose `.gitignore` doesn't cover `.loopyard/` never sees screenshots
  # as untracked files an agent might `git add -A`.
  defp ensure_gitignore(io, handle, dir) do
    case io.write_file(handle, Path.join(dir, ".gitignore"), "*\n") do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # {io module, handle}: the volume writer keyed by volume name, or the
  # container io keyed by container name.
  defp io_for({:workspace, workspace_id}),
    do: {writer(), Workspace.volume_name_for(workspace_id)}

  defp io_for({:container, container, _home}), do: {container_io(), container}

  defp writer, do: Application.get_env(:loopyard, :attachment_writer, Loopyard.VolumeIO)
  defp container_io, do: Application.get_env(:loopyard, :container_io, Loopyard.ContainerIO)
end
