defmodule Loopyard.Tools.Container.FileUrl do
  use Loopyard.Tool,
    name: "file_url",
    description:
      "Get a clickable URL to view a workspace file with syntax highlighting in the browser.",
    busy_words: ["linking a file", "URL crafting"],
    params: [
      agent_id: {:string, required: true},
      path:
        {:string,
         required: true,
         description: "File path relative to /workspace (e.g. 'Gemfile', 'app/models/user.rb')"}
    ]

  @doc """
  Returns a relative path — works from any host because the browser
  resolves it relative to wherever Loopyard is loaded.
  """
  def execute(%{agent_id: agent_id, path: path}, _assigns) do
    case Loopyard.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        volume_name = Loopyard.Workspace.volume_name_for(workspace_id)
        workspace = Loopyard.ProjectRegistry.get_workspace(workspace_id)
        project_id = workspace && workspace[:project_id]

        if project_id do
          clean =
            path
            |> String.trim_leading("/")
            |> String.trim_leading("./")
            |> String.trim_leading("workspace/")

          {:ok,
           Path.join([
             "/projects",
             project_id,
             "workspaces",
             workspace_id,
             "volumes",
             volume_name,
             "files",
             clean
           ])}
        else
          {:error, "Could not determine project for workspace #{workspace_id}"}
        end

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end
end
