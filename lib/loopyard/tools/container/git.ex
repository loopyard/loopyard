defmodule Loopyard.Tools.Container.Git do
  use Loopyard.Tool,
    name: "git",
    description:
      "Run a git command on the project repo. Each workspace is locked to its branch — checkout/switch are blocked (create a new workspace for a different branch). Reading other branches is fine: diff main, log origin/main..HEAD, show main:file, merge main, rebase main, cherry-pick, etc.",
    busy_words: ["git-ing", "committing", "versioning"],
    params: [
      agent_id: {:string, required: true},
      command:
        {:string,
         required: true,
         description:
           "Git subcommand and args (e.g. 'status', 'diff main', 'add -A', 'commit -m \"fix bug\"', 'log --oneline -10', 'merge main')"}
    ]

  @doc """
  Runs `git <command>` on the host workspace path.

  Only works for Local workspaces — the host has the .git directory.
  GitHub workspaces don't have host-side git access.
  """
  alias Loopyard.Tools.Container.Pagination

  def execute(%{agent_id: agent_id, command: command}, _assigns) do
    case Loopyard.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        run_git(workspace_id, command)

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  # Commands that change which branch the workspace is on.
  # Each workspace IS a branch — switching breaks the invariant.
  @branch_switch_commands ~w(checkout switch worktree)

  defp run_git(workspace_id, command) do
    args = OptionParser.split(command)

    case args do
      [subcmd | _] when subcmd in @branch_switch_commands ->
        {:error,
         "Cannot #{subcmd} — a workspace is a worktree locked to ONE branch. " <>
           "To work on a different branch, that's a new workspace. " <>
           "You can still read other branches: git diff main, git show main:file, git merge main, etc."}

      # A workspace IS a worktree on a branch — branching means creating a new
      # workspace, and deleting a branch means deleting one. Route those through
      # the gated (human-approved) workspace flow instead of raw git.
      ["branch" | rest] ->
        cond do
          Enum.any?(rest, &(&1 in ["-d", "-D", "--delete"])) ->
            {:error,
             "To remove a branch, use `propose_delete_workspace` — a branch's workspace is the worktree, " <>
               "and deleting it is the destructive, human-approved action."}

          Enum.any?(rest, &(not String.starts_with?(&1, "-"))) ->
            {:error,
             "To create a branch, use `propose_fork` — branching means a new workspace (its own worktree + env), " <>
               "which the user approves. `git branch` (no name) to list is fine."}

          true ->
            # Listing branches (no name, just flags like -a/-v) — allowed.
            run_git_for_workspace(workspace_id, args, command)
        end

      _ ->
        run_git_for_workspace(workspace_id, args, command)
    end
  end

  # Volume-backed workspaces keep their `.git` INSIDE the code volume (at
  # /workspace), reachable only through the container — run git there. Legacy
  # Local workspaces keep the host worktree path.
  defp run_git_for_workspace(workspace_id, args, command) do
    if volume_based?(workspace_id) do
      run_git_in_container(workspace_id, args, command)
    else
      run_git_host(workspace_id, args, command)
    end
  end

  defp run_git_host(workspace_id, args, command) do
    case host_git_path(workspace_id) do
      {:ok, path} ->
        case System.cmd("git", args,
               cd: path,
               stderr_to_stdout: true,
               env: [{"GIT_TERMINAL_PROMPT", "0"}]
             ) do
          {output, 0} -> {:ok, Pagination.cap(output)}
          {output, code} -> {:error, "git #{command} failed (exit #{code}):\n#{Pagination.cap(output)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_git_in_container(workspace_id, args, command) do
    case Loopyard.Workspace.ensure_working(workspace_id) do
      {:ok, container} ->
        git_args = Enum.map_join(args, " ", &shq/1)

        # safe.directory + a default identity so commits work in the container.
        # (Per-participant authorship is a future refinement.)
        cmd =
          "git config --global --add safe.directory /workspace 2>/dev/null; " <>
            "git config --global user.email 'loopyard@local' 2>/dev/null; " <>
            "git config --global user.name 'Loopyard' 2>/dev/null; " <>
            "git -C /workspace #{git_args}"

        case Loopyard.Docker.exec_in(container, cmd) do
          {:ok, output} -> {:ok, Pagination.cap(output)}
          {:error, output} -> {:error, "git #{command} failed:\n#{Pagination.cap(output)}"}
        end

      {:error, reason} ->
        {:error, "Couldn't reach the workspace container for git: #{inspect(reason)}"}
    end
  end

  defp volume_based?(workspace_id) do
    case Loopyard.ProjectRegistry.get_workspace(workspace_id) do
      %{volume_based: true} -> true
      _ -> false
    end
  end

  # Single-quote an arg for safe interpolation into the container shell command.
  defp shq(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  defp host_git_path(workspace_id) do
    with %{project_id: project_id} = workspace <-
           Loopyard.ProjectRegistry.get_workspace(workspace_id),
         %{source_type: :local} <- Loopyard.ProjectRegistry.get_project(project_id) do
      # For Local workspaces, the worktree path IS the host git dir
      case Loopyard.Source.Local.checkout_path(workspace) do
        nil ->
          # Fallback to workspace path
          {:ok, workspace.path}

        path ->
          {:ok, path}
      end
    else
      %{source_type: other} ->
        {:error,
         "Git tool only works for Local workspaces (this is #{other}). Git state lives on the host."}

      nil ->
        {:error, "Workspace #{workspace_id} not found"}
    end
  end
end
