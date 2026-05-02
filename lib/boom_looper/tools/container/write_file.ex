defmodule BoomLooper.Tools.Container.WriteFile do
  use BoomLooper.Tool,
    name: "write_file",
    description:
      "Write a file to the workspace. Use for Dockerfile, docker-compose.yml, config files, etc. Path is relative to /workspace.",
    busy_words: ["writing", "authoring", "crafting"],
    params: [
      agent_id: {:string, required: true},
      path:
        {:string,
         required: true,
         description:
           "File path relative to /workspace (e.g. '.boomlooper/workspace/Dockerfile' or '.boomlooper/workspace/docker-compose.yml')"},
      content: {:string, required: true, description: "File content"}
    ]

  alias BoomLooper.Tools.Container.Helpers

  # Compose files are parsed and rejected here so the agent gets the
  # error immediately at write time, not hours later when compose-up
  # fails. The same validator runs again in `Compose.process_agent_compose/3`
  # — defense in depth: even if someone writes the file out-of-band, it
  # can't boot a host-mounted container.
  defp validate_compose_if_needed(path, content) do
    if String.ends_with?(path, "docker-compose.yml") do
      case parse_and_validate_compose(content) do
        :ok -> :ok
        {:error, _} = err -> err
      end
    else
      :ok
    end
  end

  defp parse_and_validate_compose(content) do
    parsed =
      case Jason.decode(content) do
        {:ok, map} ->
          {:ok, map}

        {:error, _} ->
          case YamlElixir.read_from_string(content) do
            {:ok, map} -> {:ok, map}
            {:error, _} -> :skip
          end
      end

    case parsed do
      {:ok, compose} -> BoomLooper.Compose.validate_no_host_mounts(compose)
      # Unparseable content — let compose-up itself surface the syntax
      # error. We only enforce the boundary; we're not a linter.
      :skip -> :ok
    end
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

          with :ok <- validate_compose_if_needed(path, content),
               :ok <- BoomLooper.VolumeManager.write_file(volume_name, path, content) do
            {:ok, "Wrote #{byte_size(content)} bytes to #{path}"}
          else
            {:error, reason} when is_binary(reason) ->
              {:error, reason}

            {:error, reason} ->
              {:error, "Failed to write file: #{inspect(reason)}"}
          end

        _ ->
          {:error, "Agent #{agent_id} has no workspace"}
      end
    end
  end
end
