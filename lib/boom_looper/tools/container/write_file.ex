defmodule BoomLooper.Tools.Container.WriteFile do
  @moduledoc false

  alias BoomLooper.Tools.Container.Helpers

  def __tool_name__, do: "write_file"

  def __description__,
    do:
      "Write a file to the workspace. Use for Dockerfile, docker-compose.yml, config files, etc. Path is relative to /workspace."

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "agent_id" => %{"type" => "string"},
        "path" => %{
          "type" => "string",
          "description" =>
            "File path relative to /workspace (e.g. '.boomlooper/workspace/Dockerfile' or '.boomlooper/workspace/docker-compose.yml')"
        },
        "content" => %{"type" => "string", "description" => "File content"}
      },
      "required" => ["agent_id", "path", "content"]
    }
  end

  def execute(%{agent_id: agent_id, path: path, content: content}, _assigns) do
    with {:ok, _} <- Helpers.validate_workspace_path(path),
         :ok <- Helpers.validate_string(path, "path", 500),
         :ok <- Helpers.validate_string(content, "content", 1_000_000) do
      case BoomLooper.ChatAgent.get_state(agent_id) do
        %{workspace_id: workspace_id} when is_binary(workspace_id) ->
          volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)

          # Substitute variables in compose files
          content =
            if String.ends_with?(path, "docker-compose.yml") do
              content
              |> String.replace("${CODE_VOLUME}", volume_name)
              |> String.replace("${WORKSPACE_ID}", workspace_id)
            else
              content
            end

          case BoomLooper.VolumeManager.write_file(volume_name, path, content) do
            :ok -> {:ok, "Wrote #{byte_size(content)} bytes to #{path}"}
            {:error, reason} -> {:error, "Failed to write file: #{reason}"}
          end

        _ ->
          {:error, "Agent #{agent_id} has no workspace"}
      end
    end
  end
end
