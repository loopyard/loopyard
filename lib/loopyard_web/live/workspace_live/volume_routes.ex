defmodule LoopyardWeb.Live.WorkspaceLive.VolumeRoutes do
  @moduledoc """
  `handle_params` bodies for the volume routes — Files browser, Changes (git),
  History, diffs, and commit views. Each function takes the socket (+ route
  params) and returns `{:noreply, socket}`; WorkspaceLive's `handle_params`
  clauses are thin delegates. Split out for the module-size invariant.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_patch: 2, start_async: 3]

  alias LoopyardWeb.Live.WorkspaceLive.{DataLoader, DiffLoader, FileBrowser}

  @doc "Bare /volumes/:name → default to the files view (more useful than info)."
  def volume_redirect(socket, name) do
    {:noreply, push_patch(socket, to: "#{socket.assigns.base_path}/volumes/#{name}/files")}
  end

  @doc "File browser root: /volumes/:name/files"
  def files_root(socket, name) do
    socket = setup_volume(socket, name, :files)
    {:noreply, FileBrowser.enter_root(socket, name)}
  end

  @doc """
  File browser path: /volumes/:name/files/*path — could be a file or a
  directory; FileBrowser probes both and the :file_content handle_async
  dispatches on the returned shape.
  """
  def file(socket, name, path_parts) do
    file_path = Path.join(path_parts)
    socket = setup_volume(socket, name, :files)
    {:noreply, FileBrowser.enter_path(socket, name, file_path)}
  end

  @doc """
  Git changes view (/git) and commit-history view (/history) — same data load,
  different center pane. Separate switcher items, not tabs.
  """
  def git_or_history(socket, name, action) do
    socket = setup_volume(socket, name, if(action == :volume_git, do: :git, else: :history))

    socket =
      if socket.assigns.git_log == [] do
        git_assigns = Map.take(socket.assigns, [:project, :workspace_entry])
        start_async(socket, :git_data, fn -> DataLoader.load_git_data(git_assigns) end)
      else
        socket
      end

    {:noreply, socket}
  end

  @doc "Working-tree file diff (`kind` :unstaged or :staged)."
  def diff(socket, name, path_parts, kind) do
    file_path = Path.join(path_parts)
    socket = setup_volume(socket, name, :git)
    %{project: project, workspace_entry: workspace_entry} = socket.assigns

    {:noreply,
     socket
     |> assign(:diff_content, :loading)
     |> assign(:diff_path, file_path)
     |> start_async(:git_file_diff, fn ->
       DiffLoader.file_diff(project, workspace_entry, file_path, kind)
     end)}
  end

  @doc "Commit detail: /volumes/:name/git/commits/:sha"
  def commit(socket, name, sha) do
    socket = setup_volume(socket, name, :git)
    %{project: project, workspace_entry: workspace_entry} = socket.assigns

    {:noreply,
     socket
     |> assign(:commit_detail, :loading)
     |> assign(:commit_sha, sha)
     |> start_async(:git_commit_detail, fn ->
       DiffLoader.commit_detail(project, workspace_entry, sha)
     end)}
  end

  @doc "One file's diff within a commit."
  def commit_file(socket, name, sha, path_parts) do
    file_path = Path.join(path_parts)
    socket = setup_volume(socket, name, :git)
    %{project: project, workspace_entry: workspace_entry} = socket.assigns

    {:noreply,
     socket
     |> assign(:diff_content, :loading)
     |> assign(:diff_path, file_path)
     |> assign(:commit_sha, sha)
     |> start_async(:git_file_diff, fn ->
       DiffLoader.commit_file_diff(project, workspace_entry, sha, file_path)
     end)}
  end

  # Select the volume + reset per-volume assigns when switching volumes.
  defp setup_volume(socket, name, tab) do
    is_code = String.contains?(name, "code")

    adapter =
      if socket.assigns[:project], do: Loopyard.Source.for_project(socket.assigns.project)

    supports_git = is_code && adapter && Loopyard.Source.supports_git?(adapter)

    socket =
      if socket.assigns[:selected_volume] != name do
        socket
        |> assign(:selected_id, nil)
        |> assign(:selected_agent, nil)
        |> assign(:selected_service, nil)
        |> assign(:selected_volume, name)
        |> assign(:nav_volume, name)
        |> FileBrowser.reset()
        |> assign(:git_log, [])
        |> assign(:git_status, [])
        |> assign(:diff_content, nil)
        |> assign(:supports_git, supports_git)
      else
        socket
      end

    assign(socket, :volume_tab, tab)
  end
end
