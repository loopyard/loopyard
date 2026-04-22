defmodule BoomLooper.Tools.Container.Edit do
  use BoomLooper.Tool,
    name: "edit",
    description: "Atomic find/replace in a workspace file. PREFER THIS over read_file+write_file for changes — it's atomic, cheaper in tokens (just the diff, not the whole file twice), and gives clear errors if old_string isn't unique. Use replace_all for refactors that touch every occurrence.",
    busy_words: ["editing", "surgically modifying", "tweaking", "patching"],
    params: [
      agent_id: {:string, required: true},
      path: {:string, required: true, description: "File path relative to /workspace (e.g. 'app/javascript/dashboard/i18n/locale/en/login.json')"},
      old_string: {:string, required: true, description: "Exact text to replace. Must be unique in the file unless replace_all=true. Multi-line strings work — pass with literal newlines."},
      new_string: {:string, required: true, description: "Replacement text. Pass empty string to delete."},
      replace_all: {:boolean, description: "Replace every occurrence (default: false — fails if old_string appears more than once)"}
    ]

  alias BoomLooper.Tools.Container.Helpers

  def execute(
        %{agent_id: agent_id, path: path, old_string: old_string, new_string: new_string} =
          params,
        _assigns
      ) do
    replace_all? = Map.get(params, :replace_all, false)

    with {:ok, _} <- Helpers.validate_workspace_path(path) do
      cond do
        old_string == "" ->
          {:error, "old_string must not be empty (use write_file to create a new file)"}

        old_string == new_string ->
          {:error, "old_string and new_string are identical — nothing to change"}

        true ->
          with {:ok, workspace_id} <- Helpers.agent_workspace_id(agent_id) do
            volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)

            case BoomLooper.VolumeManager.read_file(volume_name, path) do
              {:ok, content} ->
                edit_in_memory(volume_name, path, content, old_string, new_string, replace_all?)

              {:error, :not_found} ->
                {:error, "File not found: #{path}"}

              {:error, reason} ->
                {:error, "Failed to read #{path}: #{inspect(reason)}"}
            end
          end
      end
    end
  end

  defp edit_in_memory(volume_name, path, content, old, new, replace_all?) do
    occurrences =
      content
      |> String.split(old)
      |> length()
      |> Kernel.-(1)

    cond do
      occurrences == 0 ->
        {:error,
         "old_string not found in #{path}. The file does NOT contain the literal text you " <>
           "passed. Use `grep` to find the actual text in context, then retry with the exact match."}

      occurrences > 1 and not replace_all? ->
        {:error,
         "old_string appears #{occurrences} times in #{path}. Either pass replace_all: true to " <>
           "change all of them, or expand old_string with surrounding context until it's unique."}

      true ->
        new_content =
          if replace_all? do
            String.replace(content, old, new, global: true)
          else
            String.replace(content, old, new, global: false)
          end

        case BoomLooper.VolumeManager.write_file(volume_name, path, new_content) do
          :ok ->
            replaced = if replace_all?, do: occurrences, else: 1

            # Show the changed region so the agent can verify without
            # a follow-up read_file call. Find where the replacement
            # landed and show 3 lines of context around it.
            snippet = changed_region(new_content, new, 3)

            {:ok, "Replaced #{replaced} occurrence(s) in #{path}\n\n#{snippet}"}

          {:error, reason} ->
            {:error, "Failed to write #{path}: #{inspect(reason)}"}
        end
    end
  end

  # Extract a few lines around where the replacement landed.
  defp changed_region(content, new_string, context) do
    lines = String.split(content, "\n")

    # Find the first line containing the new text
    match_idx =
      Enum.find_index(lines, fn line -> String.contains?(line, String.split(new_string, "\n") |> hd()) end)

    if match_idx do
      start = max(match_idx - context, 0)
      stop = min(match_idx + context, length(lines) - 1)

      lines
      |> Enum.slice(start..stop)
      |> Enum.with_index(start + 1)
      |> Enum.map(fn {line, num} -> "#{num}\t#{line}" end)
      |> Enum.join("\n")
    else
      ""
    end
  end
end
