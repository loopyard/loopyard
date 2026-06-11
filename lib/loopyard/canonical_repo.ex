defmodule Loopyard.CanonicalRepo do
  @moduledoc """
  The hub-and-spokes git storage engine (Foundation B / v1, see issues #13/#19).

  Each project has ONE **canonical** bare repo, living in its own Docker volume
  (`loopyard-<project_id>-canonical`) — the hub, the source of truth. Nobody
  works in it. Workspaces are **clones** of it in their own code volumes (the
  spokes), each on its own branch. Git moves code between them:

    * `fork/4`      — clone canonical → a workspace volume, on a new branch.
    * `integrate/4` — rebase the workspace's branch onto canonical `main` and
                      fast-forward `main` to it (the merge gate).
    * `push/3` / `init_from_remote/3` — sync the canonical with a git remote
                      (GitHub); the "sync container" role.

  **Everything is git in a transient container.** Each operation runs
  `docker run --rm` against a small git image with the relevant volume(s)
  mounted, all through `Loopyard.Docker.docker/2` (the single Docker path).
  No persistent git server, no host paths, no Mutagen.

  `init/1` (empty repo, new project) and `init_from_remote/3` (clone an existing
  remote) are the two onboarding doors — same destination, differing only in
  whether the canonical is seeded from a remote.
  """

  alias Loopyard.{Docker, VolumeManager, VolumeCloner}

  # Small image with git; entrypoint overridden to sh so we control the command.
  @git_image "alpine/git:latest"
  @identity ~s(git config --global user.email loopyard@local && git config --global user.name Loopyard && git config --global init.defaultBranch main)

  @doc "Canonical bare-repo volume name for a project."
  @spec volume_name(String.t()) :: String.t()
  def volume_name(project_id), do: "loopyard-#{project_id}-canonical"

  @doc """
  Create an EMPTY canonical repo (new/blank project) with a `main` branch that
  has an initial empty commit, so workspaces have something to fork from.
  """
  @spec init(String.t()) :: {:ok, String.t()} | {:error, term()}
  def init(project_id) do
    canon = volume_name(project_id)

    cmd = """
    #{@identity} && \
    git init --bare --initial-branch=main /canonical && \
    git clone /canonical /tmp/seed && cd /tmp/seed && \
    git commit --allow-empty -m "Initial commit" && \
    git push origin main
    """

    with :ok <- VolumeManager.create_volume(canon),
         {:ok, _} <- git([{canon, "/canonical"}], cmd) do
      {:ok, canon}
    end
  end

  @doc """
  Create a canonical repo seeded from an existing git remote (existing project).
  `remote` is a URL string, or `{:volume, name}` for a local bare repo (tests /
  another canonical). `opts[:token]` injects a token into a URL for auth.
  """
  @spec init_from_remote(String.t(), String.t() | {:volume, String.t()}, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def init_from_remote(project_id, remote, opts \\ []) do
    canon = volume_name(project_id)
    {extra_mounts, url} = remote_spec(remote, opts[:token])

    cmd = "#{@identity} && git clone --bare #{shq(url)} /canonical"

    with :ok <- VolumeManager.create_volume(canon),
         {:ok, _} <- git([{canon, "/canonical"} | extra_mounts], cmd, timeout: 300_000) do
      {:ok, canon}
    end
  end

  @doc """
  Fork: materialize a workspace volume as a clone of the canonical, on
  `new_branch` cut from `base` (e.g. "main" or another branch). The workspace's
  `origin` is the canonical (reachable when Loopyard mounts both, e.g. at
  `integrate/4`). Returns the workspace code-volume name.
  """
  @spec fork(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def fork(project_id, workspace_id, base, new_branch) do
    canon = volume_name(project_id)
    ws = VolumeManager.code_volume_name(workspace_id)

    cmd =
      "git clone /canonical /workspace && cd /workspace && " <>
        "git checkout -b #{shq(new_branch)} #{shq("origin/" <> base)}"

    with :ok <- VolumeManager.create_volume(ws),
         {:ok, _} <- git([{canon, "/canonical"}, {ws, "/workspace"}], cmd) do
      {:ok, ws}
    end
  end

  @doc """
  Fork from a LIVE workspace: copy the source workspace's code volume — its
  full working tree (including uncommitted edits), its gitignored `.loopyard/`
  infra (Dockerfile, docker-compose.yml), and its `.git` — into a fresh volume,
  then cut `new_branch` from the copy's current HEAD.

  This is "branch THIS and try something else": the new workspace is a true
  copy of the running one, just on its own branch + volume, so it boots with
  the same env and the same in-progress work. (`fork/4` clones the canonical
  bare repo instead — committed state only, no infra — for "new branch from
  main" when there's no live workspace to copy.) Returns the new volume name.
  """
  @spec fork_from_workspace(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def fork_from_workspace(source_ws_id, new_ws_id, new_branch) do
    src = VolumeManager.code_volume_name(source_ws_id)
    dst = VolumeManager.code_volume_name(new_ws_id)

    # cp -a preserves perms + dotfiles (.git, .loopyard). checkout -b keeps the
    # working tree, so uncommitted changes ride along onto the new branch.
    cmd =
      "cp -a /src/. /workspace/ && cd /workspace && #{@identity} && " <>
        "git config --global --add safe.directory /workspace && " <>
        "git checkout -b #{shq(new_branch)}"

    with :ok <- VolumeManager.create_volume(dst),
         {:ok, _} <- git([{src, "/src"}, {dst, "/workspace"}], cmd, timeout: 300_000) do
      {:ok, dst}
    end
  end

  @doc """
  Materialize a workspace volume as a clone of the canonical on an EXISTING
  branch (e.g. "main" for the project's main workspace). Unlike `fork/4`, no
  new branch is created. Returns the workspace code-volume name.
  """
  @spec checkout(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def checkout(project_id, workspace_id, branch) do
    canon = volume_name(project_id)
    ws = VolumeManager.code_volume_name(workspace_id)

    cmd = "git clone /canonical /workspace && cd /workspace && git checkout #{shq(branch)}"

    with :ok <- VolumeManager.create_volume(ws),
         {:ok, _} <- git([{canon, "/canonical"}, {ws, "/workspace"}], cmd) do
      {:ok, ws}
    end
  end

  @doc """
  Integrate a workspace's branch back into canonical `main`: rebase the branch
  onto the latest canonical `main`, then fast-forward `main` to it. Returns
  `{:error, ...}` if the rebase hits conflicts (in production the workspace
  agent resolves those in its own env first; this is the final merge gate).
  """
  @spec integrate(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def integrate(project_id, workspace_id, branch, opts \\ []) do
    canon = volume_name(project_id)
    ws = VolumeManager.code_volume_name(workspace_id)

    cmd = """
    #{@identity} && cd /workspace && \
    git checkout #{shq(branch)} && \
    git fetch /canonical main && \
    git rebase FETCH_HEAD && \
    git push /canonical HEAD:main
    """

    git([{canon, "/canonical"}, {ws, "/workspace"}], cmd, opts)
  end

  @doc """
  Push the canonical's `main` to a git remote (GitHub) — the sync-container
  role. `remote` is a URL or `{:volume, name}`; `opts[:token]` for auth.
  """
  @spec push(String.t(), String.t() | {:volume, String.t()}, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def push(project_id, remote, opts \\ []) do
    canon = volume_name(project_id)
    {extra_mounts, url} = remote_spec(remote, opts[:token])
    refspec = Keyword.get(opts, :refspec, "main:main")

    cmd = "#{@identity} && cd /canonical && git push #{shq(url)} #{shq(refspec)}"

    git([{canon, "/canonical"} | extra_mounts], cmd, timeout: 300_000)
  end

  @doc "Remove the canonical volume for a project."
  @spec remove(String.t()) :: :ok | {:error, term()}
  def remove(project_id), do: VolumeManager.delete_volume(volume_name(project_id))

  # --- internals ---

  # Run a shell command in a transient git container with volumes mounted.
  defp git(mounts, cmd, opts \\ []) do
    vol_args = Enum.flat_map(mounts, fn {vol, path} -> ["-v", "#{vol}:#{path}"] end)
    args = ["run", "--rm", "--entrypoint", "sh"] ++ vol_args ++ [@git_image, "-c", cmd]
    Docker.docker(args, timeout: Keyword.get(opts, :timeout, 120_000))
  end

  # Normalize a remote into {extra_mounts, git_url_inside_container}.
  defp remote_spec({:volume, vol}, _token), do: {[{vol, "/remote"}], "/remote"}

  defp remote_spec(url, token) when is_binary(url) do
    url =
      if is_binary(token) and token != "", do: VolumeCloner.inject_token(url, token), else: url

    {[], url}
  end

  # Single-quote for sh, escaping embedded quotes.
  defp shq(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
