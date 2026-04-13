defmodule BoomLooper.Tools.Container.FileUrl do
  use BoomLooper.Tool,
    name: "file_url",
    description: "Get a clickable URL to view a workspace file with syntax highlighting in the browser.",
    params: [
      agent_id: {:string, required: true},
      path: {:string, required: true, description: "File path relative to /workspace (e.g. 'Gemfile', 'app/models/user.rb')"}
    ]

  def execute(%{agent_id: agent_id, path: path}, _assigns) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} = state when is_binary(workspace_id) ->
        volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)
        workspace = BoomLooper.ProjectRegistry.get_workspace(workspace_id)
        project_id = workspace && workspace[:project_id]

        if project_id do
          clean = path |> String.trim_leading("/") |> String.trim_leading("./") |> String.trim_leading("workspace/")
          # Use the user's connection origin, not hardcoded localhost
          base = state[:base_url] || fallback_base_url()

          {:ok, "#{base}/projects/#{project_id}/workspaces/#{workspace_id}/volumes/#{volume_name}/files/#{clean}"}
        else
          {:error, "Could not determine project for workspace #{workspace_id}"}
        end

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  defp fallback_base_url do
    port = Application.get_env(:boom_looper, BoomLooperWeb.Endpoint)[:http][:port] || 4000
    "http://localhost:#{port}"
  end
end
