defmodule BoomLooper.Tools.Container.Volumes do
  @moduledoc false

  def __tool_name__, do: "volumes"
  def __description__, do: "List and inspect Docker volumes for this workspace"

  def input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "agent_id" => %{"type" => "string"},
        "action" => %{
          "type" => "string",
          "description" => "Action: 'list' (default), 'ls <volume> [path]', 'info <volume>'"
        }
      },
      "required" => ["agent_id"]
    }
  end

  def execute(%{agent_id: agent_id} = params, _assigns) do
    action = Map.get(params, :action, "list")

    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        case parse_volume_action(action) do
          {:list} ->
            case BoomLooper.VolumeManager.list_workspace_volumes(workspace_id) do
              {:ok, volumes} -> {:ok, Jason.encode!(volumes, pretty: true)}
              {:error, reason} -> {:error, reason}
            end

          {:ls, volume_name, path} ->
            BoomLooper.VolumeManager.volume_ls(volume_name, path)

          {:info, volume_name} ->
            case BoomLooper.VolumeManager.volume_info(volume_name) do
              nil -> {:error, "Volume not found: #{volume_name}"}
              info -> {:ok, Jason.encode!(info, pretty: true)}
            end
        end

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  defp parse_volume_action(action) do
    case String.split(String.trim(action), ~r/\s+/, parts: 3) do
      ["list"] -> {:list}
      ["ls", volume] -> {:ls, volume, "/"}
      ["ls", volume, path] -> {:ls, volume, path}
      ["info", volume] -> {:info, volume}
      _ -> {:list}
    end
  end
end
