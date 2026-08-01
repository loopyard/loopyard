defmodule Loopyard.Tools.Container.WriteFile do
  use Loopyard.Tool,
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
           "File path relative to /workspace (e.g. '.loopyard/workspace/Dockerfile' or '.loopyard/workspace/docker-compose.yml')"},
      content: {:string, required: true, description: "File content"}
    ]

  alias Loopyard.Tools.Container.Helpers

  # Compose files are parsed and rejected here so the agent gets the
  # error immediately at write time, not hours later when compose-up
  # fails. The same validator runs again in `Compose.process_agent_compose/3`
  # — defense in depth: even if someone writes the file out-of-band, it
  # can't boot a host-mounted container.
  defp portability_note(same, same), do: ""

  defp portability_note(_original, _rewritten),
    do:
      " — rewrote a hardcoded code-volume name to ${CODE_VOLUME} so this compose" <>
        " stays valid on every branch (it resolves when the cluster starts)."

  # Any literal loopyard code-volume name becomes ${CODE_VOLUME} again. Matches
  # ANY workspace's name, not just this one: a compose copied from a sibling
  # branch carries THAT branch's id, and leaving it is how a fork ends up
  # mounting the source's code.
  @code_volume_literal ~r/loopyard-[A-Za-z0-9_-]+-code/

  defp deliteralize_code_volume(content, volume_name) do
    content
    |> String.replace(@code_volume_literal, "${CODE_VOLUME}")
    |> String.replace(volume_name, "${CODE_VOLUME}")
  end

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
      {:ok, compose} -> Loopyard.Compose.validate_no_host_mounts(compose)
      # Unparseable content — let compose-up itself surface the syntax
      # error. We only enforce the boundary; we're not a linter.
      :skip -> :ok
    end
  end

  def execute(%{agent_id: agent_id, path: path, content: content}, _assigns) do
    with {:ok, _} <- Helpers.validate_workspace_path(path),
         :ok <- Helpers.validate_string(path, "path", 500),
         :ok <- Helpers.validate_string(content, "content", 1_000_000) do
      case Loopyard.ChatAgent.get_state(agent_id) do
        %{workspace_id: workspace_id} when is_binary(workspace_id) ->
          volume_name = Loopyard.Workspace.volume_name_for(workspace_id)

          # KEEP COMPOSE PORTABLE. We used to resolve ${CODE_VOLUME} and
          # ${WORKSPACE_ID} here, baking this workspace's id into the bytes on
          # disk — so `.loopyard/workspace/docker-compose.yml`, which git
          # carries to every branch, ended up naming ONE workspace's volume
          # (`name: loopyard-261219b7-code`). On another branch that file reads
          # as foreign, stale infrastructure, and an agent rewrites it instead
          # of reusing it. The cluster still ran, because
          # `Compose.normalize_code_volume_names/2` silently corrects a foreign
          # name at process time — which is exactly why it stayed invisible:
          # the system worked while the file lied.
          #
          # Resolution belongs at RUN time (`Compose.process_agent_compose/3`
          # already does it) so the file stays true on every branch. Going the
          # other way, a literal an agent hardcoded is rewritten back to the
          # placeholder.
          original = content

          content =
            if String.ends_with?(path, "docker-compose.yml") do
              deliteralize_code_volume(content, volume_name)
            else
              content
            end

          with :ok <- validate_compose_if_needed(path, content),
               :ok <- Loopyard.VolumeManager.write_file(volume_name, path, content) do
            {:ok,
             "Wrote #{byte_size(content)} bytes to #{path}#{portability_note(original, content)}"}
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
