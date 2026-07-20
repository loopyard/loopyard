defmodule Loopyard.Tools.ControlPlane.CreateProjectFromScratch do
  use Loopyard.Tool,
    name: "create_project_from_scratch",
    description:
      "Propose a brand-new EMPTY project (blank git repo). Shows the user an " <>
        "Approve/Deny card and WAITS. On approval, creates the project + its main " <>
        "workspace and spawns a workspace agent to set it up — you do NOT set it up " <>
        "yourself. Use when the user wants to start something fresh.",
    busy_words: ["proposing a project", "awaiting approval"],
    params: [
      agent_id: {:string, required: true},
      name: {:string, required: true, description: "Project name, e.g. 'my-idea'"},
      reason: {:string, description: "Short why — shown on the approval card"}
    ]

  alias Loopyard.Tools.ControlPlane
  alias Loopyard.Onboarding

  def execute(%{agent_id: id, name: name} = p, _assigns) do
    action = %{
      verb: :create_project,
      source: :scratch,
      name: name,
      detail: "from scratch — blank repo",
      reason: Map.get(p, :reason)
    }

    ControlPlane.provision(
      id,
      action,
      fn _progress -> Onboarding.create_project(name) end,
      ControlPlane.setup_brief(name, "created from scratch — an empty repo")
    )
  end
end
