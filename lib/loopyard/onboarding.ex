defmodule Loopyard.Onboarding do
  @moduledoc """
  v1 canonical-backed onboarding (#19) — the "one flow" door.

  `create_project/2` is the single entry point for both new and existing
  projects (they differ only in whether the canonical is seeded from a remote):

    * new/blank  → `CanonicalRepo.init/1`
    * existing   → `CanonicalRepo.init_from_remote/3` (pass `remote:`)

  It creates the canonical repo, registers the project, and materializes a
  **code-ready** `main` workspace (a clone of the canonical on `main`). It does
  NOT bring up a compose/preview env — that's the opt-in step. `fork/3` cuts a
  new branch + workspace from a base.

  Because the canonical engine materializes volumes synchronously, workspaces
  are registered `:ready` directly (skipping the Source-adapter setup saga).
  """

  alias Loopyard.{CanonicalRepo, ProjectRegistry, WorkspaceRegistry, VolumeManager, Workspace}

  @doc """
  Create a project (new blank, or existing via `remote:`), register it, and
  return `{:ok, project, main_workspace}` with a code-ready `main` workspace.
  """
  @spec create_project(String.t(), keyword()) ::
          {:ok, map(), map()} | {:error, term()}
  def create_project(name, opts \\ []) do
    project_id = uid()
    ws_id = uid()
    remote = opts[:remote]

    init =
      if remote,
        do: CanonicalRepo.init_from_remote(project_id, remote, opts),
        else: CanonicalRepo.init(project_id)

    with {:ok, _canon} <- init,
         {:ok, _ws_vol} <- CanonicalRepo.checkout(project_id, ws_id, "main") do
      project =
        ProjectRegistry.register(%{
          id: project_id,
          name: name,
          is_git: true,
          volume_based: true,
          canonical: true,
          canonical_volume: CanonicalRepo.volume_name(project_id),
          source_type: :github,
          source_config: %{remote: remote},
          added_at: DateTime.utc_now()
        })

      ws = register_workspace(project_id, ws_id, "main", is_main: true)
      {:ok, project, ws}
    end
  end

  @doc """
  Fork a new branch + workspace from `base` (any existing branch). Returns
  `{:ok, workspace}` — a code-ready, isolated clone on `branch`.
  """
  @spec fork(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fork(project_id, base, branch) do
    ws_id = uid()

    with {:ok, _ws_vol} <- CanonicalRepo.fork(project_id, ws_id, base, branch) do
      {:ok, register_workspace(project_id, ws_id, branch, is_main: false)}
    end
  end

  # --- internals ---

  defp register_workspace(project_id, ws_id, branch, opts) do
    ws = %{
      id: ws_id,
      project_id: project_id,
      name: branch,
      branch: branch,
      volume: VolumeManager.code_volume_name(ws_id),
      volume_based: true,
      path: Workspace.compose_dir(ws_id),
      is_main: Keyword.get(opts, :is_main, false),
      status: :stopped,
      # The fork/checkout already materialized the volume — no saga needed.
      setup: Loopyard.Workspace.Setup.ready_setup_field(),
      added_at: DateTime.utc_now()
    }

    WorkspaceRegistry.insert(ws_id, ws)
    WorkspaceRegistry.get_workspace(ws_id)
  end

  defp uid, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
end
