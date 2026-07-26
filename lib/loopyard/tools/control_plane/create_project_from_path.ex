defmodule Loopyard.Tools.ControlPlane.CreateProjectFromPath do
  use Loopyard.Tool,
    name: "create_project_from_path",
    description:
      "Propose a new project from a FOLDER on the host machine. Shows the user an " <>
        "Approve/Deny card and WAITS. On approval, Loopyard ingests the folder " <>
        "host-side (Local source adapter) and spawns a workspace agent to set it up. " <>
        "SECURITY: you pass only the path STRING — you never read the host " <>
        "filesystem; ingestion happens on the control plane, not in your session.",
    busy_words: ["proposing a folder", "awaiting approval"],
    params: [
      agent_id: {:string, required: true},
      name: {:string, required: true, description: "Project name in Loopyard"},
      path:
        {:string,
         required: true,
         description: "Absolute host path to the folder, e.g. '/Users/me/Projects/app'"},
      reason: {:string, description: "Short why — shown on the approval card"}
    ]

  alias Loopyard.Tools.ControlPlane
  alias Loopyard.ProjectRegistry

  def execute(%{agent_id: id, name: name, path: path} = p, _assigns) do
    action = %{
      verb: :create_project,
      source: :path,
      name: name,
      detail: "host folder: #{path}",
      reason: Map.get(p, :reason)
    }

    ControlPlane.provision(
      id,
      action,
      # Host-side ingestion only — the agent never sees the folder's contents.
      # ProjectRegistry.add/1 returns {:ok, project, workspace}.
      fn _progress -> ProjectRegistry.add(path) end,
      ControlPlane.setup_brief(name, "ingested from host folder #{path}")
    )
  end
end
