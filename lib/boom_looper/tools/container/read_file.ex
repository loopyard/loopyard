defmodule BoomLooper.Tools.Container.ReadFile do
  use BoomLooper.Tool,
    name: "read_file",
    description: "Read a file from the workspace. Supports optional line range to avoid reading huge files into context. Path is relative to /workspace.",
    params: [
      agent_id: {:string, required: true},
      path: {:string, required: true, description: "File path relative to /workspace"},
      start_line: {:integer, description: "First line to read (1-based). Omit to start from beginning."},
      end_line: {:integer, description: "Last line to read (inclusive). Omit to read to end."}
    ]

  alias BoomLooper.Tools.Container.Helpers

  def execute(%{agent_id: agent_id, path: path} = params, _assigns) do
    with {:ok, _} <- Helpers.validate_workspace_path(path) do
      case BoomLooper.ChatAgent.get_state(agent_id) do
        %{workspace_id: workspace_id} when is_binary(workspace_id) ->
          volume_name = BoomLooper.Workspace.volume_name_for(workspace_id)

          case BoomLooper.VolumeManager.read_file(volume_name, path) do
            {:ok, content} ->
              sliced = maybe_slice_lines(content, params[:start_line], params[:end_line])
              {:ok, Helpers.truncate_for_agent(sliced, max: 16_000)}

            {:error, reason} ->
              {:error, reason}
          end

        _ ->
          {:error, "Agent #{agent_id} has no workspace"}
      end
    end
  end

  defp maybe_slice_lines(content, nil, nil), do: content

  defp maybe_slice_lines(content, start_line, end_line) do
    lines = String.split(content, "\n")
    start_idx = max((start_line || 1) - 1, 0)
    end_idx = if end_line, do: min(end_line - 1, length(lines) - 1), else: length(lines) - 1

    lines
    |> Enum.slice(start_idx..end_idx)
    |> Enum.with_index(start_idx + 1)
    |> Enum.map(fn {line, num} -> "#{num}\t#{line}" end)
    |> Enum.join("\n")
  end
end
