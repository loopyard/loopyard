defmodule BoomLooper.Tools.Container.Git do
  use BoomLooper.Tool,
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
  alias BoomLooper.Tools.Container.Pagination

  def execute(%{agent_id: agent_id, command: command}, _assigns) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
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
         "Cannot #{subcmd} — each workspace is locked to its branch. " <>
           "To work on a different branch, create a new workspace. " <>
           "You can still read other branches: git diff main, git show main:file, git merge main, etc."}

      _ ->
        case host_git_path(workspace_id) do
          {:ok, path} ->
            case System.cmd("git", args,
                   cd: path,
                   stderr_to_stdout: true,
                   env: [{"GIT_TERMINAL_PROMPT", "0"}]
                 ) do
              {output, 0} ->
                {:ok, Pagination.cap(output)}

              {output, code} ->
                {:error, "git #{command} failed (exit #{code}):\n#{Pagination.cap(output)}"}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp host_git_path(workspace_id) do
    with %{project_id: project_id} = workspace <-
           BoomLooper.ProjectRegistry.get_workspace(workspace_id),
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
        {:error,
         "Git tool only works for Local workspaces (this is #{other}). Git state lives on the host."}

      nil ->
        {:error, "Workspace #{workspace_id} not found"}
    end
  end
end
