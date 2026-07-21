defmodule Loopyard.Tools.Container.Git do
  use Loopyard.Tool,
    name: "git",
    description:
      "Run git against `origin` (GitHub). Drive it normally: status/diff/log/add/commit/checkout/switch/branch/merge/rebase/cherry-pick, and push/pull/fetch feature branches freely. To LAND work on the default branch (main), use `propose_integrate` (rebased + human-approved) — a direct push to main, a force-push, or a remote-branch delete is declined here.",
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

  defp run_git(workspace_id, command) do
    args = OptionParser.split(command)

    # A workspace is a full clone (origin = GitHub), so ALL local git is free:
    # checkout, switch, branch, rebase, merge, cherry-pick. The ONLY thing the
    # tool steers is `push` — and only as a GUARDRAIL, not a security boundary
    # (an agent has raw `exec` + the token, so it can bypass this in one line;
    # real "protect main" is GitHub branch protection + the host-side, approved
    # `propose_integrate`). We nudge the compliant agent, fail-OPEN when unsure.
    case args do
      ["push" | rest] -> push_guardrail(workspace_id, rest, args, command)
      _ -> run_git_for_workspace(workspace_id, args, command)
    end
  end

  # Redirect the three outbound moves we want humans in the loop on; pass
  # everything else (feature-branch push) straight through. UX only. The arg
  # parsing (classify_push/1) is pure + tested; the branch comparison needs a
  # container read, so it's resolved here.
  defp push_guardrail(workspace_id, rest, args, command) do
    case classify_push(rest) do
      :force ->
        {:error,
         "Force-push is disallowed (it rewrites shared history). Rebase and push a " <>
           "fresh branch, or land via `propose_integrate`."}

      :delete ->
        {:error,
         "Deleting a remote branch isn't done from here — a human does that in the UI/GitHub."}

      {:target, branch} ->
        gate_if_default(workspace_id, branch, args, command)

      :current ->
        gate_if_default(
          workspace_id,
          git_read(workspace_id, "branch --show-current"),
          args,
          command
        )
    end
  end

  @doc """
  Classify a `git push` from its args (everything after `push`). Pure.

    * `:force`  — `--force`/`-f`/`--force-with-lease`, or a `+`-prefixed refspec
    * `:delete` — `--delete`/`-d`, or a `:branch` (empty-source) refspec
    * `{:target, branch}` — explicit `git push <remote> <refspec>`; `branch` is
      the REMOTE side of a `local:remote` refspec, else the ref itself
    * `:current` — bare `git push` / `git push <remote>` → the current branch
  """
  def classify_push(rest) do
    flags = Enum.filter(rest, &String.starts_with?(&1, "-"))
    positionals = Enum.reject(rest, &String.starts_with?(&1, "-"))

    force? =
      Enum.any?(flags, &(&1 in ~w(--force -f --force-with-lease))) or
        Enum.any?(positionals, &String.starts_with?(&1, "+"))

    delete? =
      Enum.any?(flags, &(&1 in ~w(--delete -d))) or
        Enum.any?(positionals, &String.starts_with?(&1, ":"))

    cond do
      force? -> :force
      delete? -> :delete
      match?([_remote, _refspec | _], positionals) -> {:target, push_target(positionals)}
      true -> :current
    end
  end

  defp push_target([_remote, refspec | _]) do
    case String.split(refspec, ":", parts: 2) do
      [_, remote_ref] -> remote_ref
      [ref] -> ref
    end
  end

  # Gate a resolved target branch: block ONLY the default branch; fail-OPEN
  # (unknown/blank target → allow) so a legit feature push never gets blocked.
  defp gate_if_default(workspace_id, target, args, command) do
    default = default_branch(workspace_id)

    if is_binary(target) and target != "" and target == default do
      {:error,
       "Pushing to the default branch directly isn't the path — use `propose_integrate` " <>
         "to land your work on main (rebased + human-approved). Push feature branches freely."}
    else
      run_git_for_workspace(workspace_id, args, command)
    end
  end

  # The repo's default branch name via `origin/HEAD`; "main" if unresolved.
  defp default_branch(workspace_id) do
    case git_read(workspace_id, "symbolic-ref --short refs/remotes/origin/HEAD") do
      "origin/" <> b when b != "" -> b
      b when is_binary(b) and b != "" -> b
      _ -> "main"
    end
  end

  # Run a read-only git query in the container; trimmed output or nil.
  defp git_read(workspace_id, subcmd) do
    with {:ok, container} <- Loopyard.Workspace.ensure_working(workspace_id),
         {:ok, out} <-
           Loopyard.Docker.exec_in(container, "git -C /workspace #{subcmd} 2>/dev/null") do
      String.trim(out)
    else
      _ -> nil
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
          {output, 0} ->
            {:ok, Pagination.cap(output)}

          {output, code} ->
            {:error, "git #{command} failed (exit #{code}):\n#{Pagination.cap(output)}"}
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
        # GIT_TERMINAL_PROMPT=0: a push/pull needing credentials FAILS FAST (~1s)
        # instead of hanging on an interactive prompt with no tty. Auth itself is
        # supplied by the gh credential helper configured in Workstation.Env
        # (reads the identity's GITHUB_TOKEN) — see login: true below, which
        # sources ~/.profile so that token + gh are in scope.
        cmd =
          "export GIT_TERMINAL_PROMPT=0; " <>
            "git config --global --add safe.directory /workspace 2>/dev/null; " <>
            "git config --global user.email 'loopyard@local' 2>/dev/null; " <>
            "git config --global user.name 'Loopyard' 2>/dev/null; " <>
            "git -C /workspace #{git_args}"

        case Loopyard.Docker.exec_in(container, cmd, login: true) do
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
