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

  alias Loopyard.{
    CanonicalRepo,
    ProjectRegistry,
    WorkspaceRegistry,
    VolumeManager,
    Workspace,
    Compose
  }

  alias Loopyard.Tools.Container.Helpers

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
      persist(project_id)
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
      ws = register_workspace(project_id, ws_id, branch, is_main: false)
      persist(project_id)
      {:ok, ws}
    end
  end

  @doc """
  Attach (or change) the git remote a project syncs to — the "hook up GitHub
  later" move (#13). Persisted. `remote_url` is a git URL string.
  """
  @spec attach_remote(String.t(), String.t()) :: :ok | {:error, term()}
  def attach_remote(project_id, remote_url) when is_binary(remote_url) do
    case ProjectRegistry.get_project(project_id) do
      nil ->
        {:error, :not_found}

      project ->
        source_config = Map.put(project.source_config || %{}, :remote, remote_url)
        ProjectRegistry.register(Map.put(project, :source_config, source_config))
        persist(project_id)
        :ok
    end
  end

  @doc """
  Sync (push) the project's canonical `main` to its git remote — the
  sync-container role (#13). `opts[:remote]` overrides the project's remote
  (e.g. a local bare repo in tests); `opts[:token]` for auth.
  """
  @spec sync(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def sync(project_id, opts \\ []) do
    project = ProjectRegistry.get_project(project_id)
    remote = opts[:remote] || (project && project.source_config[:remote])

    cond do
      is_nil(project) ->
        {:error, :not_found}

      is_nil(remote) ->
        {:error, :no_remote}

      true ->
        CanonicalRepo.push(project_id, remote,
          token: opts[:token],
          refspec: Keyword.get(opts, :refspec, "main:main")
        )
    end
  end

  @doc """
  Re-register persisted canonical projects + their workspaces on boot (#19).
  Skips any whose volumes no longer exist (project/workspace was destroyed).
  """
  @spec restore() :: :ok
  def restore do
    for {project_id, entry} <- Loopyard.CanonicalStore.load(),
        VolumeManager.volume_exists?(CanonicalRepo.volume_name(project_id)) do
      ProjectRegistry.register(%{
        id: project_id,
        name: entry["name"],
        is_git: true,
        volume_based: true,
        canonical: true,
        canonical_volume: CanonicalRepo.volume_name(project_id),
        source_type: :github,
        source_config: %{remote: entry["remote"]},
        added_at: DateTime.utc_now()
      })

      for ws <- entry["workspaces"] || [],
          VolumeManager.volume_exists?(VolumeManager.code_volume_name(ws["id"])) do
        register_workspace(project_id, ws["id"], ws["branch"], is_main: ws["is_main"])
      end
    end

    :ok
  end

  @doc """
  Bring up the workspace's **preview env** — the opt-in "run it" step. Code-ready
  workspaces have no compose cluster; this materializes the agent-written compose
  from the volume to the host compose dir (processed + port-assigned) and runs
  `Compose.up`. The compose file must already exist in the volume at
  `.loopyard/workspace/docker-compose.yml` (the agent writes it).
  """
  @spec start_preview(String.t()) :: {:ok, term()} | {:error, term()}
  def start_preview(workspace_id) do
    case WorkspaceRegistry.get_workspace(workspace_id) do
      nil ->
        {:error, :not_found}

      ws ->
        # Materialize the agent-written compose from the volume → host compose
        # dir (processed + port-assigned). It writes nothing if the compose is
        # missing or rejected by the security validator, so check the result.
        Helpers.sync_volume_to_host(ws.volume, ws.compose_dir)

        if File.exists?(Compose.compose_path(ws.compose_dir)) do
          case Compose.up(ws.compose_dir, ws.id) do
            {:ok, out} ->
              WorkspaceRegistry.update_workspace_status(ws.id, :running)
              {:ok, out}

            err ->
              err
          end
        else
          {:error,
           "No usable docker-compose.yml in the workspace " <>
             "(.loopyard/workspace/docker-compose.yml). Write one (and pass the " <>
             "security validator) before starting the preview."}
        end
    end
  end

  @doc "Tear down the workspace's preview env."
  @spec stop_preview(String.t()) :: :ok | {:error, term()}
  def stop_preview(workspace_id) do
    case WorkspaceRegistry.get_workspace(workspace_id) do
      nil ->
        {:error, :not_found}

      ws ->
        Compose.down(ws.compose_dir, ws.id)
        WorkspaceRegistry.update_workspace_status(ws.id, :stopped)
        :ok
    end
  end

  # --- internals ---

  # Persist a project's current state (name, remote, workspaces) to disk so it
  # survives a restart. Called after create_project + fork.
  defp persist(project_id) do
    project = ProjectRegistry.get_project(project_id)
    workspaces = WorkspaceRegistry.list_workspaces(project_id)

    Loopyard.CanonicalStore.put(project_id, %{
      "name" => project.name,
      "remote" => project.source_config[:remote],
      "workspaces" =>
        Enum.map(workspaces, fn ws ->
          %{"id" => ws.id, "branch" => ws.branch, "is_main" => ws.is_main}
        end)
    })
  end

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
