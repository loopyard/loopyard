defmodule Loopyard.Workspace.WorkContainer do
  @moduledoc """
  The **cheap, Loopyard-owned agent container** — the place an agent (and a
  human via the terminal) actually does work, *without* booting the project's
  dev/preview compose cluster.

  This is the heart of "working is the default state" (north-star D10). A
  workspace is a git branch in its own env; *most* of the time you just want to
  read/write code and run commands against the code volume — not stand up
  postgres, redis, and a dev server. The full compose cluster
  (`.loopyard/workspace/docker-compose.yml`) is the **preview env** and is
  opt-in (`Loopyard.Onboarding.start_preview/1`).

  The work container is:

    * **Stock** — built from `priv/workspace-base/Dockerfile` (alpine + git +
      gh + ssh + bash + curl + rsync). Loopyard owns it; the agent does not
      write it.
    * **Cheap** — `sleep infinity`, no build of the project image, no services.
      Boots in well under a second once the base image is cached.
    * **Code-mounted** — mounts the `loopyard-<ws>-code` volume at `/workspace`,
      so the agent sees the branch's code natively (identical macOS/Linux fs;
      no Mutagen, no host bind mount).
    * **Disposable** — `down/1` removes it; the code lives in the volume + git,
      so nothing is lost.

  Naming: `loopyard-<ws>-work`, distinct from the compose service container
  `loopyard-<ws>-workspace-1`. Both mount the same code volume, so an agent can
  exec into either; the work container is the one that's *always cheap to have*.
  """

  require Logger

  alias Loopyard.{Docker, VolumeManager}

  # Version-tagged, NOT :latest — ensure_image only builds when the tag is
  # absent, so bumping this tag is what makes an existing install rebuild after
  # a Dockerfile change (e.g. an adapter bump). Old containers keep their old
  # image until re-stamped (recreate/up).
  @image "loopyard-workspace-base:v2"
  @workdir "/workspace"

  # CONTAINMENT: hard memory ceiling on the work container. The Claude Code
  # harness (claude-code-acp + the `claude` CLI) runs INSIDE here and is a known
  # resource hog — it can leak into tens of GB. Without a cap that pressure hits
  # the whole host/VM and the user's machine becomes unresponsive. With it, the
  # kernel OOM-kills the bloated process INSIDE the container (contained) and
  # Loopyard's crash recovery restarts the session — the host never feels it.
  # Normal harness use is well under 1GB, so this only ever bites pathological
  # bloat. `--memory-swap` == `--memory` disables extra swap (no swap thrash).
  # Tunable: `config :loopyard, :work_container_memory, "8g"` (nil = no cap).
  @default_memory "8g"

  @doc "The configured hard memory cap for a work container (nil = unlimited)."
  def memory_limit, do: Application.get_env(:loopyard, :work_container_memory, @default_memory)

  @doc "Container name for a workspace's cheap work container."
  @spec container_name(String.t()) :: String.t()
  def container_name(workspace_id), do: "loopyard-#{workspace_id}-work"

  @doc "The stock base image tag the work container runs."
  @spec image() :: String.t()
  def image, do: @image

  @doc "Is the work container running?"
  @spec running?(String.t()) :: boolean()
  def running?(workspace_id), do: Docker.container_running?(container_name(workspace_id))

  @doc """
  Ensure the work container is up and mounting the workspace's code volume.

  Idempotent:

    * already running → `{:ok, name}`
    * exists but stopped → start it
    * absent → build the base image if missing, ensure the code volume, run it

  Returns `{:ok, container_name}` or `{:error, reason}`.
  """
  @spec ensure_up(String.t()) :: {:ok, String.t()} | {:error, term()}
  def ensure_up(workspace_id) do
    name = container_name(workspace_id)

    result =
      cond do
        Docker.container_running?(name) ->
          {:ok, name}

        Docker.container_exists?(name) ->
          # Stopped leftover (e.g. across a daemon restart) — start it back up.
          case Docker.docker(["start", name]) do
            {:ok, _} -> {:ok, name}
            {:error, _} -> recreate(workspace_id, name)
          end

        true ->
          recreate(workspace_id, name)
      end

    # Enforce the memory cap on EVERY up-path — a container created before this
    # cap existed (or `docker start`ed from such a state) is retro-capped here
    # without a recreate, so no long-lived container stays unbounded.
    with {:ok, up_name} <- result do
      enforce_memory_limit(up_name)
      reconcile_git_origin(workspace_id, up_name)
      {:ok, up_name}
    end
  end

  # MIGRATION: workspaces materialized before the git-host change have
  # `origin = /canonical`. Repoint to the CLEAN GitHub URL (no token) so plain
  # git reaches GitHub. Guarded to run at most ONCE per workspace per boot (a
  # persistent_term flag) — `ensure_up` is on the tool hot path, so we don't
  # want a docker exec every call. The first git use reconciles; the rest skip.
  # Idempotent, best-effort, never touches local-only projects, never blocks.
  defp reconcile_git_origin(workspace_id, name) do
    flag = {__MODULE__, :origin_reconciled, workspace_id}

    if :persistent_term.get(flag, false) do
      :ok
    else
      case project_remote(workspace_id) do
        url when is_binary(url) and url != "" ->
          # Only repoint when origin isn't already a github URL (the /canonical
          # legacy case) so we never clobber a deliberately-set remote.
          sh =
            "cur=$(git -C /workspace remote get-url origin 2>/dev/null); " <>
              "case \"$cur\" in *github.com*) : ;; *) " <>
              "git -C /workspace remote set-url origin #{shq(url)} 2>/dev/null || true ;; esac"

          _ = Docker.exec_in(name, sh)
          :persistent_term.put(flag, true)
          :ok

        _ ->
          # Local-only (or unknown) — mark done so we don't re-check every call.
          :persistent_term.put(flag, true)
          :ok
      end
    end
  rescue
    _ -> :ok
  end

  defp project_remote(workspace_id) do
    case Loopyard.ProjectRegistry.get_workspace(workspace_id) do
      %{project_id: pid} when is_binary(pid) ->
        case Loopyard.ProjectRegistry.get_project(pid) do
          %{source_config: %{remote: remote}} -> remote
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Single-quote an arg for safe interpolation into the container shell command.
  defp shq(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"

  @doc """
  Apply the configured memory cap to an already-running container (no recreate).
  `docker update` adjusts the cgroup live. Best-effort + idempotent — a no-op
  when uncapped or already at the target.
  """
  def enforce_memory_limit(name) do
    case memory_limit() do
      cap when is_binary(cap) and cap != "" ->
        _ = Docker.docker(["update", "--memory", cap, "--memory-swap", cap, name])
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Exec a shell command inside the work container, from `/workspace`.

  Brings the container up first if needed, so callers don't have to sequence
  `ensure_up` themselves. Returns `Docker.exec_in/3`'s `{:ok, output}` /
  `{:error, reason}`.
  """
  @spec exec(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def exec(workspace_id, command, opts \\ []) do
    with {:ok, name} <- ensure_up(workspace_id) do
      # login: true → source the home volume's ~/.profile so identity env (tokens)
      # is in scope, since we no longer inject it via `docker run -e`.
      opts = opts |> Keyword.put_new(:workdir, @workdir) |> Keyword.put_new(:login, true)
      Docker.exec_in(name, command, opts)
    end
  end

  @doc "Stop + remove the work container. The code volume is untouched."
  @spec down(String.t()) :: :ok
  def down(workspace_id) do
    name = container_name(workspace_id)
    _ = Docker.docker(["rm", "-f", name])
    :ok
  end

  @doc """
  Build the stock base image if it isn't present yet. Idempotent and safe to
  call on the hot path — skips the build when the image already exists.
  """
  @spec ensure_image() :: :ok | {:error, term()}
  def ensure_image do
    if image_present?() do
      :ok
    else
      context = Application.app_dir(:loopyard, "priv/workspace-base")
      Logger.info("Building stock workspace base image #{@image} from #{context}")

      case Docker.docker(["build", "-t", @image, context], timeout: 600_000) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # --- internals ---

  defp recreate(workspace_id, name) do
    volume = VolumeManager.code_volume_name(workspace_id)

    # The work container mounts its workspace's WORKSTATION identity home volume
    # (its $HOME logins/creds). Resolved from the workspace's recorded
    # `:workstation_id` — so the container is deterministic per-workspace, even on
    # a headless boot, and a workspace attached to another identity uses that
    # identity's creds. Legacy workspaces (no field) fall back to `current/0`.
    ws = Loopyard.Workspace.workstation_id(workspace_id)

    # Toolchain = the shared stock base image (identity-agnostic). Identity is the
    # home volume mounted below, NOT a per-identity image.
    with :ok <- ensure_image(),
         :ok <- ensure_volume(volume),
         # Materialize identity env into the home volume's ~/.profile (files-in-
         # $HOME), so we never inject secrets via `docker run -e`. Stage operator
         # CLIs into the volume too so they travel to any container mounting it.
         _ <- Loopyard.Workstation.Env.sync_home(ws),
         _ <- Loopyard.Workstation.Env.stage_tools(ws),
         # Carry the driver's Claude identity (skills/commands/agents/CLAUDE.md)
         # into the home volume so the in-container harness isn't a blank slate,
         # and pre-trust its cwds so project CLAUDE.md/.claude actually load.
         _ <- Loopyard.Workstation.Env.sync_claude(ws),
         _ <- Loopyard.Workstation.Env.trust_projects(ws),
         # Clear any stopped container of the same name before run.
         _ <- Docker.docker(["rm", "-f", name]),
         # `rm -f` returns before Docker finishes reaping the container; running
         # immediately races it and hits "container is marked for removal and
         # cannot be started". Wait for the name to actually free up first.
         :ok <- wait_for_name_free(name),
         {:ok, _} <- run_idempotent(name, volume, ws) do
      {:ok, name}
    end
  end

  # `docker run --name` can still lose a race and hit
  # "Conflict. The container name ... is already in use" — a squatter appeared
  # between our rm -f/wait and the run (a create raced in, or Docker's listing
  # lagged behind the actual state). Force-remove the squatter and retry once so
  # ensure_up stays idempotent against leftover state instead of failing the
  # caller. (docker-e2e hit this on a shared canonical workspace id.)
  defp run_idempotent(name, volume, ws) do
    case run(name, volume, ws) do
      {:ok, _} = ok ->
        ok

      {:error, output} = err ->
        if output =~ "already in use" or output =~ "Conflict" do
          _ = Docker.docker(["rm", "-f", name])
          _ = wait_for_name_free(name)
          run(name, volume, ws)
        else
          err
        end
    end
  end

  # Poll until no container holds `name` (removal completed), up to ~2s. Gives
  # up quietly after that — run/3 will surface any genuine error.
  defp wait_for_name_free(name, tries \\ 20) do
    cond do
      not Docker.container_exists?(name) ->
        :ok

      tries <= 0 ->
        :ok

      true ->
        Process.sleep(100)
        wait_for_name_free(name, tries - 1)
    end
  end

  defp run(name, volume, ws) do
    # Mount the branch's code at /workspace AND the identity's $HOME volume at
    # /home/<id> — so the agent inherits the logins/tools the user set up
    # (gh/claude/fly/mise), exactly like every other agent. `$HOME` is set to the
    # mount so every tool resolves creds there. We keep **root** (the pet model
    # installs tools live — apt/mise/gem need it); non-root is a cattle/prod
    # concern. Env (tokens) is NOT injected via `-e`; it lives as files in the
    # home volume (`~/.loopyard/env`, sourced by `~/.profile`) — see
    # Env.sync_home/1 and Docker.with_login_profile/1.
    home = home_path(ws)

    Docker.docker(
      [
        "run",
        "-d",
        "--name",
        name,
        "--init"
      ] ++
        memory_args() ++
        [
          "-v",
          "#{volume}:#{@workdir}",
          "-v",
          "#{Loopyard.Workstation.Container.home_volume(ws)}:#{home}",
          "-e",
          "HOME=#{home}",
          "-w",
          @workdir,
          @image,
          "sleep",
          "infinity"
        ]
    )
  end

  # --memory + --memory-swap (swap == memory disables extra swap). Omitted
  # entirely when the cap is configured to nil, so opting out is clean.
  defp memory_args do
    case memory_limit() do
      nil -> []
      "" -> []
      mem -> ["--memory", to_string(mem), "--memory-swap", to_string(mem)]
    end
  end

  # The identity's $HOME inside the container: /home/<id>.
  defp home_path(ws), do: "/home/#{ws}"

  defp ensure_volume(volume) do
    if VolumeManager.volume_exists?(volume), do: :ok, else: VolumeManager.create_volume(volume)
  end

  defp image_present? do
    case Docker.docker(["image", "inspect", @image], retry: false) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
end
