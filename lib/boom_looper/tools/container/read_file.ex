defmodule BoomLooper.Tools.Container.ReadFile do
  use BoomLooper.Tool,
    name: "read_file",
    description: "Read a file from the workspace. Path is relative to /workspace.",
    params: [
      agent_id: {:string, required: true},
      path: {:string, required: true, description: "File path relative to /workspace"}
    ]

  alias BoomLooper.Tools.Container.Helpers

  def execute(%{agent_id: agent_id, path: path}, _assigns) do
    with {:ok, _} <- Helpers.validate_workspace_path(path) do
      case BoomLooper.ChatAgent.get_state(agent_id) do
        %{workspace_id: workspace_id} when is_binary(workspace_id) ->
          volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)
          BoomLooper.VolumeManager.read_file(volume_name, path)

        _ ->
          {:error, "Agent #{agent_id} has no workspace"}
      end
    end
  end
end
