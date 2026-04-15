defmodule BoomLooperWeb.Live.WorkspaceLive.FileBrowser do
  @moduledoc """
  Volume file-browser orchestration for `WorkspaceLive`.

  The file browser lives inside the workspace view at
  `/volumes/:name/files[/:path]`. Two entry points (root listing and
  path view), plus one async probe that decides whether a path is a
  file or a directory.

  Pulled out of `WorkspaceLive` so "how does browsing work" is one
  module to read. The LiveView still owns `handle_async` clauses
  (they route back to LV by name), but the bodies delegate here.
  """

  import Phoenix.LiveView, only: [start_async: 3]
  import Phoenix.Component, only: [assign: 3]

  alias BoomLooper.{VolumeIO, VolumeManager}

  @doc """
  Enter the browser at a volume's root. Resets path/content state and
  kicks off an async tree load.
  """
  def enter_root(socket, volume_name) do
    socket
    |> assign(:browse_path, ".")
    |> assign(:file_content, nil)
    |> assign(:file_path, nil)
    |> assign(:file_tree, :loading)
    |> start_async(:file_tree, fn -> VolumeManager.tree(volume_name, ".") end)
  end

  @doc """
  Enter the browser at a specific path. The path may be a file OR a
  directory — `probe_path/2` decides at load time and the LiveView's
  `:file_content` handle_async has a clause for each outcome.
  """
  def enter_path(socket, volume_name, file_path) do
    dir = parent_dir(file_path)

    socket
    |> assign(:browse_path, dir)
    |> assign(:file_tree, :loading)
    |> assign(:file_content, :loading)
    |> assign(:file_path, file_path)
    |> start_async(:file_tree, fn -> VolumeManager.tree(volume_name, dir) end)
    |> start_async(:file_content, fn -> probe_path(volume_name, file_path) end)
  end

  @doc """
  Decide whether `path` in `volume_name` is a file, a directory, or
  missing. Returns one of:

    * `%{path: path, content: binary}` — readable file
    * `%{path: path, is_dir: true, entries: list}` — directory
    * `%{path: path, not_found: true, content: nil}` — neither

  The LiveView's `handle_async(:file_content, ...)` pattern-matches on
  the shape to assign the right state.
  """
  def probe_path(volume_name, file_path) do
    case VolumeIO.read_file(volume_name, file_path) do
      {:ok, content} ->
        %{path: file_path, content: content}

      {:error, _} ->
        case VolumeManager.tree(volume_name, file_path) do
          {:ok, entries} -> %{path: file_path, is_dir: true, entries: entries}
          {:error, _} -> %{path: file_path, content: nil, not_found: true}
        end
    end
  end

  @doc """
  Reset browser assigns — called from `setup_volume` when the user
  switches between volumes so stale state doesn't leak.
  """
  def reset(socket) do
    socket
    |> assign(:file_tree, nil)
    |> assign(:file_content, nil)
    |> assign(:file_path, nil)
    |> assign(:browse_path, ".")
  end

  defp parent_dir(file_path) do
    case Path.dirname(file_path) do
      "." -> "."
      dir -> dir
    end
  end
end
