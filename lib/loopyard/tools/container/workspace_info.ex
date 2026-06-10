defmodule Loopyard.Tools.Container.WorkspaceInfo do
  use Loopyard.Tool,
    name: "workspace_info",
    description:
      "Get workspace metadata: ID, volume, your always-on work container, and where to define the dev-service cluster. For LIVE running state, use `service_containers`.",
    busy_words: ["checking workspace", "getting bearings"],
    params: [
      agent_id: {:string, required: true}
    ]

  def execute(%{agent_id: agent_id}, _assigns) do
    case Loopyard.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        volume_name = Loopyard.Workspace.volume_name_for(workspace_id)
        project_dir = Loopyard.Workspace.compose_dir(workspace_id)
        compose_project = Loopyard.Compose.project_name(workspace_id)

        info = %{
          workspace_id: workspace_id,
          volume_name: volume_name,
          project_dir: project_dir,
          compose_project: compose_project,
          # Where YOU define the opt-in dev-service cluster (postgres, dev
          # server, …). Bring it up with the `docker_compose` tool.
          compose_file: ".loopyard/workspace/docker-compose.yml",
          dockerfile: ".loopyard/workspace/Dockerfile",
          # Your always-on, code-mounted container (where `exec`/tools run).
          # The compose cluster is separate and only exists once you start it.
          work_container: Loopyard.Workspace.WorkContainer.container_name(workspace_id),
          preview_running: Loopyard.Workspace.container_running?(workspace_id)
        }

        {:ok, Jason.encode!(info, pretty: true)}

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end
end
