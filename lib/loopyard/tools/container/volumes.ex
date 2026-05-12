defmodule Loopyard.Tools.Container.Volumes do
  use Loopyard.Tool,
    name: "volumes",
    description:
      "List and inspect Docker volumes for this workspace. Foreign volumes are rejected — you can only see volumes belonging to your own workspace.",
    params: [
      agent_id: {:string, required: true},
      action:
        {:string, description: "Action: 'list' (default), 'ls <volume> [path]', 'info <volume>'"}
    ]

  def execute(%{agent_id: agent_id} = params, _assigns) do
    action = Map.get(params, :action, "list")

    case Loopyard.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        case parse_volume_action(action) do
          {:list} ->
            case Loopyard.VolumeManager.list_workspace_volumes(workspace_id) do
              {:ok, volumes} -> {:ok, Jason.encode!(volumes, pretty: true)}
              {:error, reason} -> {:error, reason}
            end

          {:ls, volume_name, path} ->
            with :ok <- authorize_volume(workspace_id, volume_name) do
              Loopyard.VolumeManager.volume_ls(volume_name, path)
            end

          {:info, volume_name} ->
            with :ok <- authorize_volume(workspace_id, volume_name) do
              case Loopyard.VolumeManager.volume_info(volume_name) do
                nil -> {:error, "Volume not found: #{volume_name}"}
                info -> {:ok, Jason.encode!(info, pretty: true)}
              end
            end
        end

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  # Enforce workspace boundary: a volume belongs to a workspace iff its
  # name starts with "loopyard-<workspace_id>". This is the same prefix used
  # by VolumeManager.list_workspace_volumes/1.
  defp authorize_volume(workspace_id, volume_name) when is_binary(volume_name) do
    if String.starts_with?(volume_name, "loopyard-#{workspace_id}") do
      :ok
    else
      {:error,
       "Volume #{volume_name} does not belong to this workspace. You can only access " <>
         "volumes prefixed with bl-#{workspace_id}. Use `volumes list` to see yours."}
    end
  end

  defp authorize_volume(_, _), do: {:error, "volume name must be a string"}

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
