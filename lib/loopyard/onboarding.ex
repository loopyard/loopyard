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

    # A cloned repo's main branch is whatever the REMOTE says it is — assuming
    # "main" fails outright on every `master` repo, and the operator's
    # create_project_from_github goes through here. A blank repo has no remote
    # to ask, so it starts on "main" by convention.
    branch =
      if remote, do: Loopyard.Git.default_branch(remote, opts[:token]) || "main", else: "main"

    with {:ok, _canon} <- init,
         {:ok, _ws_vol} <- CanonicalRepo.checkout(project_id, ws_id, branch, remote) do
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

      ws = register_workspace(project_id, ws_id, branch, is_main: true)
      persist(project_id)
      # Always-on per branch: bring the cheap work container up now so the
      # branch is a live, workable box the moment it exists (no cold start when
      # you start working). Best-effort + async — never block creation on it.
      start_work_async(ws_id)
      # Multiplayer: every open project list updates without a refresh.
      Loopyard.Events.Projects.publish(%Loopyard.Events.Projects.Changed{
        action: :created,
        project_id: project_id
      })

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

    with {:ok, _ws_vol} <-
           CanonicalRepo.fork(project_id, ws_id, base, branch, project_remote(project_id)) do
      ws = register_workspace(project_id, ws_id, branch, is_main: false)
      persist(project_id)
      start_work_async(ws_id)
      {:ok, ws}
    end
  end

  @doc """
  Fork from a LIVE workspace — copy `source_ws_id`'s volume (working tree +
  `.loopyard` infra + git history) onto a new branch in its own volume. This is
  what an agent's `propose_fork` should do: "branch THIS workspace and try
  something else" brings the in-progress files and the env config along, so the
  new workspace boots ready instead of empty. See
  `CanonicalRepo.fork_from_workspace/3`.
  """
  @spec fork_from_workspace(String.t(), String.t(), String.t(), (String.t() -> any())) ::
          {:ok, map()} | {:error, term()}
  def fork_from_workspace(project_id, source_ws_id, branch, progress \\ fn _ -> :ok end) do
    ws_id = uid()

    # progress.(step) streams creation phases to the caller (e.g. the approval
    # card) so a multi-second fork shows what it's doing instead of a dead spinner.
    progress.("Forking the code volume…")

    with {:ok, _ws_vol} <-
           CanonicalRepo.fork_from_workspace(
             source_ws_id,
             ws_id,
             branch,
             project_remote(project_id)
           ) do
      progress.("Registering the workspace…")
      ws = register_workspace(project_id, ws_id, branch, is_main: false)
      persist(project_id)
      progress.("Starting the environment…")
      start_work_async(ws_id)

      # Boot the fork's preview cluster from the `.loopyard` config it carries —
      # "branch this and keep working" means the dev server should come up, not a
      # dead sidebar. Async + best-effort: the fork is usable immediately; services
      # come up in the background and the sidebar goes green via the Observer.
      # Safe now that code-volume names are normalized to THIS workspace
      # (see Compose.normalize_code_volume_names); no-ops if there's no compose.
      # (Previously gated on `preview_running?(source)`, which checked for a
      # compose service literally named "workspace" — real compose files name
      # their services dev/postgres/etc, so it was always false and forks never
      # booted their services.)
      progress.("Starting services…")
      start_preview_async(ws_id)

      {:ok, ws}
    end
  end

  @doc """
  Spawn an agent — THE single spawn path (`Loopyard.Agents.Spawn`), for every
  scope. `spawn_agent(template_id, opts)` stamps that template;
  `spawn_agent(workspace_id, opts)` is the shim every existing caller uses
  and means "a coding agent in that workspace". Workspace ids are 16 hex
  chars and template ids are words, so the two never collide.

  Returns `{:ok, agent_id}` or `{:error, reason}`.
  """
  @spec spawn_agent(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def spawn_agent(template_or_ws_id, opts \\ [])

  def spawn_agent(id, opts) when is_binary(id) do
    if Loopyard.Agents.Template.exists?(id),
      do: Loopyard.Agents.Spawn.spawn(id, opts),
      else: Loopyard.Agents.Spawn.spawn("coding", Keyword.put(opts, :workspace_id, id))
  end

  @doc """
  Bring the workspace's preview cluster up in the BACKGROUND — best-effort, so a
  freshly-cloned workspace is browsable immediately and its services come up
  behind it (the sidebar goes green via the Observer). Called at the end of every
  provisioning path (fork here, `Workspace.Setup` for UI-created workspaces) so a
  cloned workspace boots the `.loopyard` config it came with, instead of landing
  with a dead service sidebar. Safe when there's no compose: `start_preview/1`
  no-ops with a logged error rather than crashing.
  """
  @spec start_preview_async(String.t()) :: :ok
  def start_preview_async(ws_id) do
    Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn -> start_preview(ws_id) end)
    :ok
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
        # Always-on per branch: bring each restored branch's work container back
        # up after a server restart (best-effort, async).
        start_work_async(ws["id"])
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

  @doc """
  Make a workspace **workable right now** — the default state (north-star D10).

  Brings up the cheap, code-mounted `WorkContainer` (no project image, no
  services) so an agent can read/write code and run commands immediately,
  *without* the preview cluster. This is what "working is the default" means:
  you don't boot containers to start working; you boot containers (the preview
  env) only when you want to *run* the app.

  Idempotent. Returns `{:ok, container_name}` or `{:error, reason}`.
  """
  @spec start_working(String.t()) :: {:ok, String.t()} | {:error, term()}
  def start_working(workspace_id) do
    case WorkspaceRegistry.get_workspace(workspace_id) do
      nil -> {:error, :not_found}
      ws -> Loopyard.Workspace.ensure_working(ws.id)
    end
  end

  @doc """
  Stop the cheap work container. Does NOT touch the preview cluster or the code
  volume — purely releases the lightweight agent container.
  """
  @spec stop_working(String.t()) :: :ok | {:error, term()}
  def stop_working(workspace_id) do
    case WorkspaceRegistry.get_workspace(workspace_id) do
      nil -> {:error, :not_found}
      ws -> Loopyard.Workspace.WorkContainer.down(ws.id)
    end
  end

  # --- internals ---

  # The project's real git remote (GitHub URL) or nil for a local-only project.
  # Threaded into CanonicalRepo.fork/checkout so a materialized workspace's
  # `origin` points at GitHub, not the internal `/canonical`.
  defp project_remote(project_id) do
    case ProjectRegistry.get_project(project_id) do
      %{source_config: %{remote: remote}} when is_binary(remote) and remote != "" -> remote
      _ -> nil
    end
  end

  # Always-on per branch: fire-and-forget the cheap work container so a branch
  # is a live, workable box as soon as it exists / is restored. Best-effort —
  # the lazy `Workspace.ensure_working/1` on agent spawn / tool use is the
  # safety net if this misses.
  defp start_work_async(ws_id) do
    Task.Supervisor.start_child(Loopyard.TaskSupervisor, fn ->
      Loopyard.Workspace.ensure_working(ws_id)
    end)

    :ok
  end

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
      # The workstation (identity) this workspace belongs to — its creds/home the
      # agents here inherit. Recorded at creation (the operating identity), so a
      # workspace can be attached to a specific workstation instead of always
      # following the global `current`. Multi-workstation foundation.
      workstation_id: Keyword.get(opts, :workstation_id) || Loopyard.Workstation.current(),
      # The fork/checkout already materialized the volume — no saga needed.
      setup: Loopyard.Workspace.Setup.ready_setup_field(),
      added_at: DateTime.utc_now()
    }

    WorkspaceRegistry.insert(ws_id, ws)
    WorkspaceRegistry.get_workspace(ws_id)
  end

  defp uid, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
end
