defmodule BoomLooper.Source do
  @moduledoc """
  Behaviour that defines how a project's code is materialized and kept in
  sync with the host (or a remote). Each implementation — `Source.Local`,
  `Source.GitHub` (future), etc. — owns one kind of backend.

  The rest of the system (ProjectRegistry, ServiceManager, LiveViews) never
  calls into an implementation directly. It calls `Source.for_project/1` to
  resolve the adapter module, then invokes behaviour callbacks on it. That
  is the only public entry point.

  Local and other adapters can coexist at runtime: each project carries a
  `source_type` atom (`:local` | `:github`) that decides dispatch.
  """

  @type project :: map()
  @type workspace :: map()

  # --- Lifecycle ---

  @callback add_project(input :: any, opts :: keyword) ::
              {:ok, project} | {:error, term}

  @callback create_workspace(project, branch :: String.t(), opts :: keyword) ::
              {:ok, workspace} | {:error, term}

  @callback remove_workspace(project, workspace) :: :ok
  @callback remove_project(project) :: :ok

  # --- Queries (cheap — callable from render paths) ---

  @callback checkout_path(workspace) :: String.t() | nil
  @callback current_revision(workspace) :: {:ok, String.t()} | {:error, term}
  @callback dirty?(workspace) :: boolean

  # --- Container lifecycle hooks (called by ServiceManager) ---

  @callback on_container_up(workspace) :: :ok
  @callback on_container_down(workspace) :: :ok

  # --- Optional git callbacks ---

  @callback git_log(project, workspace, opts :: keyword) :: {:ok, list} | {:error, term}
  @callback git_status(project, workspace) :: {:ok, list} | {:error, term}
  @callback git_diff(project, workspace, opts :: keyword) :: {:ok, String.t()} | {:error, term}
  @callback git_diff_staged(project, workspace, opts :: keyword) :: {:ok, String.t()} | {:error, term}
  @callback git_show(project, workspace, ref :: String.t(), path :: String.t()) ::
              {:ok, String.t()} | {:error, term}
  @callback git_commit_detail(project, workspace, sha :: String.t()) :: {:ok, map} | {:error, term}
  @callback git_commit_diff(project, workspace, sha :: String.t(), opts :: keyword) :: {:ok, String.t()} | {:error, term}

  @optional_callbacks git_log: 3, git_status: 2, git_diff: 3, git_diff_staged: 3, git_show: 4, git_commit_detail: 3, git_commit_diff: 4

  @doc """
  Check if an adapter module supports git operations.
  """
  def supports_git?(adapter) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, :git_log, 3)
  end

  @doc """
  Resolve the adapter module for a project. Returns the module name.
  Falls back to `Source.Local` for legacy records missing `:source_type`.
  """
  def for_project(%{source_type: :local}), do: BoomLooper.Source.Local
  def for_project(%{source_type: :github}), do: BoomLooper.Source.GitHub
  def for_project(%{git_url: url}) when is_binary(url), do: BoomLooper.Source.GitHub
  def for_project(_), do: BoomLooper.Source.Local
end
