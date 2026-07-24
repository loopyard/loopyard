defmodule Loopyard.Tools.ControlPlane do
  @moduledoc """
  The **operator agent's** toolkit — control-plane creation, deliberately
  DISJOINT from `Tools.Container`. The operator can create projects/workspaces
  and hand off to a workspace agent; it has NO `exec`/`write_file`/`docker_compose`
  and no host-FS tools, so it structurally cannot do the workspace agent's job
  (setting up / running code). Separation of duties by construction.

  Every create is approval-gated via `Loopyard.Harness.Approvals` (the same
  Approve/Deny card as `propose_fork`), and every create ends by spawning a
  workspace agent with a delegating brief — the operator never sets up a dev env
  itself.

  Toolkit contract: `__tool_server__/0` → `%{name: "loopyard-control-plane",
  tools: [...]}`, consumed by `ChatAgent.ToolConfig`. See
  [plans/gbrain-onboarding.md].
  """

  alias Loopyard.Harness.Approvals
  alias Loopyard.Onboarding

  @tools [
    # --- The cockpit: read the whole picture, dig in, drive it (operator-hub) ---
    Loopyard.Tools.ControlPlane.Overview,
    Loopyard.Tools.ControlPlane.PeekWorkspace,
    Loopyard.Tools.ControlPlane.SystemStatus,
    Loopyard.Tools.ControlPlane.RecentActivity,
    Loopyard.Tools.ControlPlane.Ports,
    Loopyard.Tools.ControlPlane.Dispatch,
    # --- Lifecycle (all approval-gated: create + destructive delete) ---
    Loopyard.Tools.ControlPlane.CreateProjectFromScratch,
    Loopyard.Tools.ControlPlane.CreateProjectFromGithub,
    Loopyard.Tools.ControlPlane.CreateProjectFromPath,
    Loopyard.Tools.ControlPlane.DeleteWorkspace,
    Loopyard.Tools.ControlPlane.DeleteProject,
    Loopyard.Tools.ControlPlane.RenameWorkspace,
    Loopyard.Tools.ControlPlane.RenameProject,
    Loopyard.Tools.ControlPlane.Gh,
    # A real shell inside the operator's OWN container image — resolve_container
    # targets its workstation container. This is "the same tools + do whatever in
    # your image": exec covers cat/edit/git/docker/gh/install, all sandboxed to
    # the container. (The workspace-scoped container tools — git/docker_compose/
    # logs/propose_* — don't fit a container-bound, workspace-less agent, so we
    # deliberately don't hand it a pile of tools that would just error.)
    Loopyard.Tools.Container.Exec
  ]

  def __tool_server__, do: %{name: "loopyard-control-plane", tools: @tools}

  @doc """
  Shared gated-provisioning flow for the create tools. Requests approval, and on
  approval runs `create_fn` (which returns `{:ok, project, workspace}`), then
  spawns the workspace agent with `brief` (the delegating initial message), then
  resolves the approval card with the new ids. The operator stops here — the
  workspace agent takes over the setup.

    * `operator_id` — the operator agent's id (approval routing).
    * `action` — the approval-card action map (`%{verb: :create_project, ...}`).
    * `create_fn` — `(progress_fn) -> {:ok, project, ws} | {:error, reason}`.
    * `brief` — the workspace agent's initial message.
  """
  def provision(operator_id, action, create_fn, brief) do
    case Approvals.request(operator_id, action) do
      {:approve, msg_id} ->
        progress = fn step ->
          Approvals.resolve(operator_id, msg_id, %{status: :creating, detail: step})
        end

        progress.("Creating the project…")

        case create_fn.(progress) do
          {:ok, project, ws} ->
            progress.("Starting the workspace agent…")

            agent_id =
              case Onboarding.spawn_agent(ws.id, initial_message: brief, started_by: "operator") do
                {:ok, aid} -> aid
                _ -> nil
              end

            # Post a live "quote" of the workspace agent into the operator's own
            # chat — the chat-in-chat mini-app, so the user watches the setup from
            # here (Cards.agent_embed). Reference only; interaction opens it.
            if agent_id do
              Loopyard.ChatAgent.append_message_ets(operator_id, %{
                role: :embed,
                agent_id: agent_id,
                workspace_id: ws.id,
                project_id: project.id,
                label: project.name,
                timestamp: DateTime.utc_now()
              })
            end

            Approvals.resolve(operator_id, msg_id, %{
              status: :approved,
              verb: :create_project,
              project_id: project.id,
              workspace_id: ws.id,
              agent_id: agent_id
            })

            {:ok,
             "Approved. Created project '#{project.name}' (workspace #{ws.id}); a workspace " <>
               "agent is setting it up now. The user can open it from the card."}

          {:error, reason} ->
            Approvals.resolve(operator_id, msg_id, %{status: :failed, error: inspect(reason)})
            {:error, "Approved, but creating the project failed: #{inspect(reason)}"}
        end

      {:deny, _msg_id} ->
        {:ok, "The user declined to create the project."}

      {:timeout, _} ->
        {:ok, "No response on the project proposal — not created."}
    end
  end

  @doc """
  The delegating brief handed to the freshly-spawned workspace agent. Encodes the
  recipe + the docker.sock (DooD) trick for projects that themselves drive Docker.
  """
  def setup_brief(project_name, source_note) do
    """
    You are the workspace agent for the new project "#{project_name}" (#{source_note}).
    The code is at /workspace. Get the dev environment running:

    1. Inspect the stack (mix.exs / package.json / Gemfile / etc.).
    2. Write `.loopyard/workspace/Dockerfile` + `docker-compose.yml` for it,
       including any services it needs (Postgres, Redis, …).
    3. Install deps, run migrations/setup, and start the app.
    4. If this project ITSELF drives Docker (a hosting plane, a CI runner, etc.),
       do NOT run docker-in-docker — mount the host daemon into the service:
       `volumes: ["/var/run/docker.sock:/var/run/docker.sock"]` (optionally
       `DOCKER_HOST=unix:///var/run/docker.sock`). The container reaches the same
       Colima daemon that way.
    5. Verify it's reachable with `probe_http` and report the URL.
    """
  end

  @doc """
  Resolve an operator-supplied target string to a workspace agent summary.
  Accepts an agent id, a workspace id, or a workspace name (case-insensitive),
  and returns that workspace's agent (the first one). Used by `peek_workspace`
  and `dispatch` so the operator can name a target however is natural.
  """
  def resolve_agent(target) when is_binary(target) do
    t = String.trim(target)
    summaries = Loopyard.ChatAgent.list_agent_summaries()

    cond do
      hit = Enum.find(summaries, &(&1.id == t)) ->
        {:ok, hit}

      ws_id = resolve_workspace_id(t) ->
        case Enum.filter(summaries, &(&1[:workspace_id] == ws_id)) do
          [] -> {:error, "Workspace '#{target}' has no running agent. Use overview to check."}
          [agent | _] -> {:ok, agent}
        end

      true ->
        {:error,
         "No workspace or agent matched '#{target}'. Call overview to see valid ids/names."}
    end
  end

  def resolve_agent(_), do: {:error, "target must be a workspace id/name or an agent id."}

  @doc """
  Resolve a target string to a workspace id (id verbatim or case-insensitive
  name). Unlike `resolve_agent/1` this does not require a running agent — ports
  and lifecycle exist independent of agents. Used by `ports`.
  """
  def resolve_workspace(target) when is_binary(target) do
    case resolve_workspace_id(String.trim(target)) do
      nil ->
        {:error, "No workspace matched '#{target}'. Call overview to see valid ids/names."}

      ws_id ->
        {:ok, ws_id}
    end
  end

  def resolve_workspace(_), do: {:error, "target must be a workspace id or name."}

  # A workspace id verbatim, or a (case-insensitive) workspace name → its id.
  defp resolve_workspace_id(t) do
    workspaces =
      Loopyard.ProjectRegistry.list_projects()
      |> Enum.flat_map(&Loopyard.WorkspaceRegistry.list_workspaces(&1.id))

    cond do
      Enum.any?(workspaces, &(&1.id == t)) -> t
      ws = Enum.find(workspaces, &(String.downcase(&1[:name] || "") == String.downcase(t))) -> ws.id
      true -> nil
    end
  rescue
    _ -> nil
  end

  @doc "Resolve a GitHub token for cloning private repos, from the operating identity."
  def github_token do
    case System.cmd("gh", ["auth", "token"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
