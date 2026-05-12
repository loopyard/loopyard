defmodule Loopyard.Tools.Container.FileInfo do
  use Loopyard.Tool,
    name: "file_info",
    description:
      "Get file size and line count WITHOUT reading the content. Use this before read_file on unfamiliar files to decide whether to read the whole thing or use a line range.",
    params: [
      agent_id: {:string, required: true},
      path: {:string, required: true, description: "File path relative to /workspace"}
    ]

  alias Loopyard.Docker
  alias Loopyard.Tools.Container.Helpers

  def execute(%{agent_id: agent_id, path: path}, _assigns) do
    with {:ok, _} <- Helpers.validate_workspace_path(path) do
      case Helpers.resolve_container(agent_id) do
        {:ok, container} ->
          full_path = "/workspace/#{path}"

          cmd =
            "stat -c '%s' #{Helpers.shell_quote(full_path)} 2>/dev/null && wc -l < #{Helpers.shell_quote(full_path)} 2>/dev/null"

          case Docker.exec_in(container, cmd, timeout: 5_000) do
            {:ok, output} ->
              case String.split(String.trim(output), "\n") do
                [size_str, lines_str] ->
                  size = String.to_integer(String.trim(size_str))
                  lines = String.to_integer(String.trim(lines_str))

                  hint =
                    cond do
                      lines <= 100 ->
                        "Small file — safe to read_file without line range."

                      lines <= 500 ->
                        "Medium file (#{lines} lines). Consider using start_line/end_line if you only need a section."

                      true ->
                        "Large file (#{lines} lines, #{div(size, 1024)}KB). Use grep to find what you need, or read_file with start_line/end_line."
                    end

                  {:ok, "#{path}: #{lines} lines, #{size} bytes\n#{hint}"}

                _ ->
                  {:error, "Could not stat #{path} — file may not exist"}
              end

            {:error, reason} ->
              {:error, "file_info failed: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
