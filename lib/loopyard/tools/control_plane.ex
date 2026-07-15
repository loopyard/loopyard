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
    Loopyard.Tools.ControlPlane.CreateProjectFromScratch,
    Loopyard.Tools.ControlPlane.CreateProjectFromGithub,
    Loopyard.Tools.ControlPlane.CreateProjectFromPath,
    Loopyard.Tools.ControlPlane.ListProjects,
    Loopyard.Tools.ControlPlane.Gh
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
