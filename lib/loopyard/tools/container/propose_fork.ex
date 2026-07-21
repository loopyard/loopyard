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
  alias Loopyard.{WorkspaceRegistry, ChatAgent}

  def execute(%{agent_id: agent_id, branch: branch} = params, _assigns) do
    with %{workspace_id: ws_id} when is_binary(ws_id) <- ChatAgent.get_state(agent_id),
         %{project_id: project_id} = ws when is_binary(project_id) <-
           WorkspaceRegistry.get_workspace(ws_id) do
      base = Map.get(params, :base) || Map.get(ws, :branch) || "main"

      # `workspace_id` (this workspace = the fork source) rides in the action so
      # the decision handler can run the fork later WITHOUT the proposing agent's
      # live state — the card is self-contained and durable.
      action = %{
        verb: :fork,
        project_id: project_id,
        workspace_id: ws_id,
        base: base,
        branch: branch,
        reason: Map.get(params, :reason)
      }

      # Queued approval (no blocking, no TTL): post the card and return. On
      # approve, the LiveView runs `Approvals.run/3`, which forks this workspace,
      # spawns the branch's agent, and streams progress into the card.
      Approvals.post(agent_id, action)

      {:ok,
       "I've proposed forking this workspace onto a new branch '#{branch}' " <>
         "(from '#{base}'). Approve the card whenever you're ready — no time " <>
         "limit — and I'll create it with an agent ready to open."}
    else
      _ -> {:error, "Couldn't resolve the project for this workspace."}
    end
  end
end
