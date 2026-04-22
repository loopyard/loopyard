defmodule BoomLooper.Tools.Container.Git do
  use BoomLooper.Tool,
    name: "git",
    description: "Run a git command on the project repo. For Local workspaces, git runs on the HOST (not inside the container) because .git is excluded from volume sync. Supports any git subcommand: status, diff, add, commit, log, branch, etc. Commits use the host's git user.name and user.email.",
    busy_words: ["git-ing", "committing", "versioning"],
    params: [
      agent_id: {:string, required: true},
      command: {:string, required: true, description: "Git subcommand and args (e.g. 'status', 'diff', 'add -A', 'commit -m \"fix bug\"', 'log --oneline -10')"}
    ]

  @doc """
  Runs `git <command>` on the host workspace path.

  Only works for Local workspaces — the host has the .git directory.
  GitHub workspaces don't have host-side git access.
  """
  alias BoomLooper.Tools.Container.Pagination

  def execute(%{agent_id: agent_id, command: command}, _assigns) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        run_git(workspace_id, command)

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  defp run_git(workspace_id, command) do
    # Get the host-side path (where .git lives)
    case host_git_path(workspace_id) do
      {:ok, path} ->
        args = OptionParser.split(command)

        case System.cmd("git", args, cd: path, stderr_to_stdout: true, env: [{"GIT_TERMINAL_PROMPT", "0"}]) do
          {output, 0} -> {:ok, Pagination.cap(output)}
          {output, code} -> {:error, "git #{command} failed (exit #{code}):\n#{Pagination.cap(output)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp host_git_path(workspace_id) do
    with %{project_id: project_id} = workspace <- BoomLooper.ProjectRegistry.get_workspace(workspace_id),
         %{source_type: :local} <- BoomLooper.ProjectRegistry.get_project(project_id) do
      # For Local workspaces, the worktree path IS the host git dir
      case BoomLooper.Source.Local.checkout_path(workspace) do
        nil ->
          # Fallback to workspace path
          {:ok, workspace.path}

        path ->
          {:ok, path}
      end
    else
      %{source_type: other} ->
        {:error, "Git tool only works for Local workspaces (this is #{other}). Git state lives on the host."}

      nil ->
        {:error, "Workspace #{workspace_id} not found"}
    end
  end
end
