defmodule Loopyard.Tools.ControlPlane.CreateProjectFromGithub do
  use Loopyard.Tool,
    name: "create_project_from_github",
    description:
      "Propose a new project by CLONING a GitHub repo (public or private — uses " <>
        "the operating identity's GitHub auth). Shows the user an Approve/Deny card " <>
        "and WAITS. On approval, bare-clones the repo into the project's canonical " <>
        "volume, creates the main workspace, and spawns a workspace agent to set it " <>
        "up. You do NOT set it up yourself. Currently checks out the 'main' branch.",
    busy_words: ["proposing a clone", "awaiting approval"],
    params: [
      agent_id: {:string, required: true},
      name: {:string, required: true, description: "Project name in Loopyard"},
      repo: {:string, required: true, description: "GitHub repo as 'owner/name', e.g. 'overtonxyz/gbrain'"},
      reason: {:string, description: "Short why — shown on the approval card"}
    ]

  alias Loopyard.Tools.ControlPlane
  alias Loopyard.Onboarding

  def execute(%{agent_id: id, name: name, repo: repo} = p, _assigns) do
    url = "https://github.com/#{repo}"

    action = %{
      verb: :create_project,
      source: :github,
      name: name,
      detail: "clone github.com/#{repo}",
      reason: Map.get(p, :reason)
    }

    token = ControlPlane.github_token()

    ControlPlane.provision(
      id,
      action,
      fn _progress -> Onboarding.create_project(name, remote: url, token: token) end,
      ControlPlane.setup_brief(name, "cloned from github.com/#{repo}")
    )
  end
end
