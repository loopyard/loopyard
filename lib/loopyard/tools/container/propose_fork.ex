defmodule Loopyard.Tools.Container.ProposeFork do
  use Loopyard.Tool,
    name: "propose_fork",
    description:
      "Propose creating a NEW branch + isolated workspace to try something " <>
        "without touching the current one. Shows the user an Approve/Deny card and " <>
        "WAITS for their decision — only a human can create workspaces (guardrail). " <>
        "On approval, a fresh workspace is cloned from `base` onto a new branch. Use " <>
        "when the user wants to try an idea on a side branch, or before risky / " <>
        "experimental work that shouldn't disturb the current branch.",
    busy_words: ["proposing a branch", "awaiting approval"],
    params: [
      agent_id: {:string, required: true},
      branch: {:string, required: true, description: "New branch name, e.g. 'try-postgres'"},
      base:
        {:string, description: "Branch to fork from (default: the current workspace's branch)"},
      reason: {:string, description: "Short why — shown on the approval card"}
    ]

  alias Loopyard.Harness.Approvals
  alias Loopyard.{Onboarding, WorkspaceRegistry, ChatAgent}

  def execute(%{agent_id: agent_id, branch: branch} = params, _assigns) do
    with %{workspace_id: ws_id} when is_binary(ws_id) <- ChatAgent.get_state(agent_id),
         %{project_id: project_id} = ws when is_binary(project_id) <-
           WorkspaceRegistry.get_workspace(ws_id) do
      base = Map.get(params, :base) || Map.get(ws, :branch) || "main"

      action = %{
        verb: :fork,
        project_id: project_id,
        base: base,
        branch: branch,
        reason: Map.get(params, :reason)
      }

      case Approvals.request(agent_id, action) do
        {:approve, msg_id} ->
          Approvals.resolve(agent_id, msg_id, %{status: :creating, detail: "Starting…"})

          # Stream each creation phase into the card so the human watches it work
          # (mini-app progress) instead of staring at a static "Creating…" spinner.
          progress = fn step ->
            Approvals.resolve(agent_id, msg_id, %{status: :creating, detail: step})
          end

          # Copy THIS workspace (working tree + .loopyard infra), not a fresh
          # canonical clone — "branch this and try something else" should bring
          # the in-progress files and env along. `base` is just the card label.
          case Onboarding.fork_from_workspace(project_id, ws_id, branch, progress) do
            {:ok, new_ws} ->
              # Spin up the branch's agent as part of provisioning, so the fork is
              # ready WITH an agent before it becomes available — "Open" lands you
              # straight on a live chat, not a blank workspace that scrambles to
              # auto-spawn. Services keep booting in the background.
              progress.("Starting the agent…")

              new_agent_id =
                case Onboarding.spawn_agent(new_ws.id, started_by: "fork") do
                  {:ok, aid} -> aid
                  _ -> nil
                end

              Approvals.resolve(agent_id, msg_id, %{
                status: :approved,
                workspace_id: new_ws.id,
                project_id: project_id,
                agent_id: new_agent_id
              })

              {:ok,
               "Approved. Created branch '#{branch}' as a new workspace (#{new_ws.id}), " <>
                 "forked from '#{base}', with an agent ready. The user can open it from the card."}

            {:error, reason} ->
              Approvals.resolve(agent_id, msg_id, %{status: :failed, error: inspect(reason)})
              {:error, "Branch approved but creation failed: #{inspect(reason)}"}
          end

        {:deny, msg_id} ->
          Approvals.resolve(agent_id, msg_id, %{status: :denied})
          {:ok, "The user declined to create the '#{branch}' branch."}

        {:timeout, _} ->
          {:ok, "No response on the branch proposal — not created."}
      end
    else
      _ -> {:error, "Couldn't resolve the project for this workspace."}
    end
  end
end
