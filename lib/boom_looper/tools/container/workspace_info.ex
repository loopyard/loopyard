defmodule BoomLooper.Tools.Container.WorkspaceInfo do
  use BoomLooper.Tool,
    name: "workspace_info",
    description: "Get workspace metadata: ID, volume name, paths, container names",
    busy_words: ["checking workspace", "getting bearings"],
    params: [
      agent_id: {:string, required: true}
    ]

  def execute(%{agent_id: agent_id}, _assigns) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} = state when is_binary(workspace_id) ->
        volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)
        project_dir = BoomLooper.Workspace.compose_dir(workspace_id)
        compose_project = BoomLooper.Compose.project_name(workspace_id)

        info = %{
          workspace_id: workspace_id,
          volume_name: volume_name,
          project_dir: project_dir,
          compose_project: compose_project,
          compose_file: ".boomlooper/workspace/docker-compose.yml",
          dockerfile: ".boomlooper/workspace/Dockerfile",
          workspace_container: "#{compose_project}-workspace-1",
          working_dir: state[:working_dir],
          bind_mount: state[:bind_mount]
        }

        {:ok, Jason.encode!(info, pretty: true)}

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end
end
