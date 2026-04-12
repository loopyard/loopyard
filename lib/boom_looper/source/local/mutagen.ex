defmodule BoomLooper.Source.Local.Mutagen do
  @moduledoc """
  Thin wrapper over the `mutagen` CLI for managing sync sessions on behalf of
  Local workspaces.

  Each workspace has exactly one mutagen session, named `bl-<workspace_id>`,
  that syncs the host worktree at `~/.boomlooper/worktrees/<ws_id>` with
  `/workspace` inside the workspace container.

  The command runner is configurable via
  `Application.get_env(:boom_looper, :mutagen_runner, &System.cmd/3)` so unit
  tests can stub it without shelling out. Integration tests that actually run
  `mutagen` should use the `@tag :mutagen` bucket and be excluded from the
  default suite.
  """

  require Logger

  # Files/dirs we never want to sync. Two important exclusions:
  # - `.git` — the host worktree owns git state exclusively.
  # - `.boomlooper/` — agent-written Dockerfile / docker-compose.yml /
  #   agents.log stay in the volume and must never leak into the user's git
  #   history on the host.
  @ignores ~w(
    .git
    .boomlooper
    .DS_Store
    node_modules
    _build
    deps
    .elixir_ls
    target
  )

  @doc "Session name for a workspace."
  def session_name(workspace_id), do: "bl-#{workspace_id}"

  @doc "Is mutagen installed and on PATH?"
  def installed? do
    case System.find_executable("mutagen") do
      nil -> false
      _ -> true
    end
  end

  @doc """
  Create a sync session between `worktree_path` on the host and `/workspace`
  inside `container_name`. Returns `:ok` if the session is created or
  already exists with the same name, `{:error, reason}` otherwise.

  The container must be running — mutagen's `docker://` transport uses
  `docker exec` to reach the filesystem.
  """
  def start_sync(workspace_id, worktree_path, container_name) do
    name = session_name(workspace_id)

    args =
      [
        "sync",
        "create",
        "--name=#{name}",
        "--sync-mode=two-way-safe"
      ] ++
        Enum.flat_map(@ignores, fn pat -> ["--ignore=#{pat}"] end) ++
        [
          worktree_path,
          "docker://#{container_name}/workspace"
        ]

    case run(args) do
      {_out, 0} ->
        :ok

      {out, _} ->
        if String.contains?(out, "already exists") do
          :ok
        else
          {:error, String.trim(out)}
        end
    end
  end

  @doc "Terminate the sync session for a workspace. Idempotent."
  def terminate_sync(workspace_id) do
    name = session_name(workspace_id)

    case run(["sync", "terminate", name]) do
      {_out, 0} -> :ok
      {out, _} ->
        if String.contains?(out, "does not exist") or String.contains?(out, "no sessions") do
          :ok
        else
          {:error, String.trim(out)}
        end
    end
  end

  @doc "Pause the sync session for a workspace. Idempotent."
  def pause_sync(workspace_id) do
    case run(["sync", "pause", session_name(workspace_id)]) do
      {_out, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end

  @doc "Resume the sync session for a workspace. Idempotent."
  def resume_sync(workspace_id) do
    case run(["sync", "resume", session_name(workspace_id)]) do
      {_out, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end

  @doc """
  Return a coarse status atom for a workspace's session.

  `:running`  — session exists and is not paused or in error
  `:paused`   — session exists and is paused
  `:errored`  — session exists but mutagen reports a problem
  `:missing`  — no session with this name
  `:unknown`  — couldn't reach mutagen (daemon down, CLI missing)
  """
  def session_status(workspace_id) do
    name = session_name(workspace_id)

    case run(["sync", "list", name]) do
      {out, 0} ->
        parse_status(out)

      {out, _} ->
        if String.contains?(out, "does not exist") or String.contains?(out, "no sessions") do
          :missing
        else
          :unknown
        end
    end
  end

  @doc "Return session names currently known to mutagen (for reconciliation)."
  def list_session_names do
    case run(["sync", "list"]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Regex.run(~r/Name:\s*(bl-[a-zA-Z0-9-]+)/, line) do
            [_, name] -> [name]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  # --- Private ---

  # Very coarse parser. `mutagen sync list <name>` prints a block that
  # contains lines like "Status: Watching for changes" or "Status: Paused".
  # We only care about three outcomes so we match loosely on substrings.
  defp parse_status(out) do
    cond do
      String.match?(out, ~r/Status:.*Paused/i) -> :paused
      String.match?(out, ~r/Status:.*Problem/i) -> :errored
      String.match?(out, ~r/Status:.*Error/i) -> :errored
      String.match?(out, ~r/Status:.*Halted/i) -> :errored
      String.match?(out, ~r/Status:/) -> :running
      true -> :unknown
    end
  end

  defp run(args) do
    runner =
      Application.get_env(:boom_looper, :mutagen_runner) ||
        (&default_runner/1)

    runner.(args)
  end

  defp default_runner(args) do
    case System.find_executable("mutagen") do
      nil ->
        {"mutagen not found on PATH", 127}

      exe ->
        System.cmd(exe, args, stderr_to_stdout: true)
    end
  end
end
