defmodule Loopyard.Source do
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

  # Build a workspace MAP (no I/O, no ETS, no Docker). Just metadata —
  # workspace_id, project_id, branch, paths, volume name. Called
  # synchronously inside `WorkspaceRegistry.add_workspace`. The actual
  # I/O is deferred to the setup saga via the `do_*` callbacks below.
  #
  # Adapters that don't yet support new-workspace creation
  # (e.g. `Source.GitHub`) return `{:error, :not_implemented}`.
  @callback prepare_workspace(project, branch :: String.t(), opts :: keyword) ::
              {:ok, workspace} | {:error, term}

  # Legacy entry point. Equivalent to `prepare_workspace/3` plus running
  # every `do_*` callback inline. New code goes through the saga; this
  # is retained so callers we haven't migrated still work.
  @callback create_workspace(project, branch :: String.t(), opts :: keyword) ::
              {:ok, workspace} | {:error, term}

  # ── Setup-saga steps ──
  #
  # Each callback below corresponds to one phase of the workspace-setup
  # saga (`Loopyard.Workspace.Setup`). The saga runs them in order;
  # each phase's broadcast/progress event drives the SetupProgress UI.

  # `:worktree` phase. Local: create the host git worktree + copy the
  # `.loopyard` config into it. GitHub (PR2): host git clone into a
  # temp dir. Idempotent — must tolerate re-runs (Retry button).
  @callback do_create_worktree(workspace) :: :ok | {:error, term}

  # `:volume` phase. `VolumeManager.create_volume/1` for any Docker-
  # volume-backed adapter (which is everything today). Idempotent.
  @callback do_create_volume(workspace) :: :ok | {:error, term}

  # `:seeding` phase. Slow: rsync / clone code INTO the volume.
  #
  # `callback` receives stdout+stderr chunks from the underlying tool;
  # adapters wire this to `Loopyard.Workspace.Setup.ProgressParser`
  # which broadcasts `Events.WorkspaceSetup.PhaseProgress` events.
  #
  # Idempotent: must be safe on a partially-seeded volume (retry).
  # No `--delete` or destructive flags.
  @callback do_seed_volume(workspace, callback :: (binary -> any), opts :: keyword) ::
              :ok | {:error, term}

  @callback remove_workspace(project, workspace) :: :ok
  @callback remove_project(project) :: :ok

  # --- Queries (cheap — callable from render paths) ---

  @callback checkout_path(workspace) :: String.t() | nil
  @callback current_revision(workspace) :: {:ok, String.t()} | {:error, term}
  @callback dirty?(workspace) :: boolean

  # Human-readable label for the workspace. Used as the trailing
  # breadcrumb segment and as the title on the workspace overview
  # page. Adapters own this so the displayed identity matches how the
  # source actually identifies a workspace (branch for Local, eventually
  # owner/repo#branch or PR title for GitHub). Must be cheap — called
  # from render paths.
  @callback display_name(workspace) :: String.t()

  # --- Container lifecycle hooks (called by ServiceManager) ---

  @callback on_container_up(workspace) :: :ok
  @callback on_container_down(workspace) :: :ok

  # --- Optional git callbacks ---

  @callback git_log(project, workspace, opts :: keyword) :: {:ok, list} | {:error, term}
  @callback git_status(project, workspace) :: {:ok, list} | {:error, term}
  @callback git_diff_stat(project, workspace) ::
              {:ok, %{added: non_neg_integer, removed: non_neg_integer}} | {:error, term}
  @callback git_diff(project, workspace, opts :: keyword) :: {:ok, String.t()} | {:error, term}
  @callback git_diff_staged(project, workspace, opts :: keyword) ::
              {:ok, String.t()} | {:error, term}
  @callback git_show(project, workspace, ref :: String.t(), path :: String.t()) ::
              {:ok, String.t()} | {:error, term}
  @callback git_commit_detail(project, workspace, sha :: String.t()) ::
              {:ok, map} | {:error, term}
  @callback git_commit_diff(project, workspace, sha :: String.t(), opts :: keyword) ::
              {:ok, String.t()} | {:error, term}

  @optional_callbacks git_log: 3,
                      git_status: 2,
                      git_diff_stat: 2,
                      git_diff: 3,
                      git_diff_staged: 3,
                      git_show: 4,
                      git_commit_detail: 3,
                      git_commit_diff: 4

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
  def for_project(%{source_type: :local}), do: Loopyard.Source.Local
  def for_project(%{source_type: :github}), do: Loopyard.Source.GitHub
  def for_project(%{git_url: url}) when is_binary(url), do: Loopyard.Source.GitHub
  def for_project(_), do: Loopyard.Source.Local

  @doc """
  Adapter-dispatched display name for a workspace. Looks up the
  workspace's project from `ProjectRegistry`, then delegates to that
  adapter's `display_name/1`. Callers in render paths use this so the
  trailing breadcrumb / overview title always reflects how the source
  identifies the workspace (branch for Local, etc.) — no UI-stored
  alias that can drift from source state.

  Falls back to `workspace[:name]` if the project can't be resolved
  (e.g. mid-deletion) so the render path never crashes.
  """
  def display_name(%{project_id: project_id} = workspace) when is_binary(project_id) do
    case Loopyard.ProjectRegistry.get_project(project_id) do
      nil -> workspace[:name] || ""
      project -> for_project(project).display_name(workspace)
    end
  end

  def display_name(workspace) when is_map(workspace), do: workspace[:name] || ""
  def display_name(_), do: ""
end
