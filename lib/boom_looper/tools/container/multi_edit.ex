defmodule BoomLooper.Tools.Container.MultiEdit do
  use BoomLooper.Tool,
    name: "multi_edit",
    description: "Apply many edits to one file as a single atomic read-modify-write. Cheaper than calling `edit` N times. Edits run in order against the running result, so a later edit can match text produced by an earlier one. If ANY edit fails, the file is not written.",
    params: [
      agent_id: {:string, required: true},
      path: {:string, required: true, description: "File path relative to /workspace"},
      edits: {:string, required: true, description: "JSON array of edits, e.g. '[{\"old_string\": \"foo\", \"new_string\": \"bar\"}, {\"old_string\": \"baz\", \"new_string\": \"qux\", \"replace_all\": true}]'"}
    ]

  alias BoomLooper.Tools.Container.Helpers

  def execute(%{agent_id: agent_id, path: path, edits: edits}, _assigns) do
    case Jason.decode(to_string(edits)) do
      {:ok, list} when is_list(list) ->
        apply_multi_edit(agent_id, path, list)

      {:ok, _} ->
        {:error, "edits must be a JSON array"}

      {:error, reason} ->
        {:error, "edits is not valid JSON: #{inspect(reason)}"}
    end
  end

  defp apply_multi_edit(agent_id, path, edits) when is_list(edits) do
    with {:ok, _} <- Helpers.validate_workspace_path(path) do
      cond do
        edits == [] ->
          {:error, "edits list must not be empty"}

        true ->
          with {:ok, workspace_id} <- Helpers.agent_workspace_id(agent_id) do
            volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)

            case BoomLooper.VolumeManager.read_file(volume_name, path) do
              {:ok, content} ->
                apply_edits_to_content(volume_name, path, content, edits)

              {:error, :not_found} ->
                {:error, "File not found: #{path}"}

              {:error, reason} ->
                {:error, "Failed to read #{path}: #{inspect(reason)}"}
            end
          end
      end
    end
  end

  defp apply_edits_to_content(volume_name, path, content, edits) do
    Enum.reduce_while(edits, {:ok, content, 0}, fn edit, {:ok, current, idx} ->
      old = edit["old_string"] || edit[:old_string]
      new = edit["new_string"] || edit[:new_string]
      replace_all? = edit["replace_all"] || edit[:replace_all] || false

      cond do
        is_nil(old) or old == "" ->
          {:halt, {:error, "edit ##{idx + 1}: old_string is missing or empty"}}

        is_nil(new) ->
          {:halt, {:error, "edit ##{idx + 1}: new_string is missing"}}

        true ->
          occurrences = (current |> String.split(old) |> length()) - 1

          cond do
            occurrences == 0 ->
              {:halt,
               {:error,
                "edit ##{idx + 1}: old_string not found (after #{idx} prior edits applied)"}}

            occurrences > 1 and not replace_all? ->
              {:halt,
               {:error,
                "edit ##{idx + 1}: old_string appears #{occurrences} times — pass replace_all: true or expand the context"}}

            true ->
              new_content = String.replace(current, old, new, global: replace_all?)
              {:cont, {:ok, new_content, idx + 1}}
          end
      end
    end)
    |> case do
      {:ok, new_content, count} ->
        case BoomLooper.VolumeManager.write_file(volume_name, path, new_content) do
          :ok ->
            {:ok, "Applied #{count} edit(s) to #{path} (#{byte_size(new_content)} bytes)"}

          {:error, reason} ->
            {:error, "Failed to write #{path}: #{inspect(reason)}"}
        end

      {:error, _} = err ->
        err
    end
  end
end
