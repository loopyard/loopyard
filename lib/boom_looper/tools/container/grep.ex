defmodule BoomLooper.Tools.Container.Grep do
  use BoomLooper.Tool,
    name: "grep",
    description: "Recursive content search inside the workspace. Returns structured matches (file:line: content). PREFER THIS over `exec(\"grep -rn ...\")`. Excludes .git/node_modules/vendor/_build/deps/.next/dist/target/.venv/__pycache__ automatically.",
    params: [
      agent_id: {:string, required: true},
      pattern: {:string, required: true, description: "Text to search for. Fixed string by default — pass regex=true for extended regex (grep -E)."},
      path: {:string, description: "Subdirectory under /workspace to search (default: whole workspace)"},
      include: {:string, description: "File pattern to filter, e.g. '*.json' or '*.{ts,vue}'"},
      regex: {:boolean, description: "Treat pattern as extended regex (default: false — fixed string)"},
      output_mode: {:string, description: "'lines' (default — file:line: content) or 'files' (just unique file paths)"},
      head_limit: {:integer, description: "Max matches to return (default: 200)"}
    ]

  alias BoomLooper.Docker
  alias BoomLooper.Tools.Container.Helpers

  def execute(%{agent_id: agent_id, pattern: pattern} = params, _assigns) do
    path = Map.get(params, :path, ".") |> Helpers.normalize_search_path()
    include = Map.get(params, :include)
    regex? = Map.get(params, :regex, false)
    output_mode = Map.get(params, :output_mode, "lines")
    head_limit = Map.get(params, :head_limit, 200)

    with {:ok, _} <- Helpers.validate_workspace_path(path) do
      cond do
        pattern == "" ->
          {:error, "pattern must not be empty"}

        true ->
          grep_in_container(agent_id, pattern, path, include, regex?, output_mode, head_limit)
      end
    end
  end

  defp grep_in_container(agent_id, pattern, path, include, regex?, output_mode, head_limit) do
    case Helpers.resolve_container(agent_id) do
      {:ok, container} ->
        flags = ["-rn", "--color=never"]
        flags = if regex?, do: flags ++ ["-E"], else: flags ++ ["-F"]

        flags =
          flags ++
            [
              "--exclude-dir=.git",
              "--exclude-dir=node_modules",
              "--exclude-dir=vendor",
              "--exclude-dir=_build",
              "--exclude-dir=deps",
              "--exclude-dir=.next",
              "--exclude-dir=dist",
              "--exclude-dir=target",
              "--exclude-dir=.venv",
              "--exclude-dir=__pycache__"
            ]

        flags = if include, do: flags ++ ["--include=#{include}"], else: flags

        full_path = Path.join("/workspace", path)

        cmd =
          "grep #{Enum.join(flags, " ")} #{Helpers.shell_quote(pattern)} #{Helpers.shell_quote(full_path)} 2>/dev/null | head -n #{head_limit}"

        case Docker.exec_in(container, cmd, timeout: 30_000) do
          {:ok, ""} ->
            {:ok, "No matches for #{inspect(pattern)} in #{path}"}

          {:ok, output} ->
            format_grep_output(output, output_mode, head_limit)

          {:error, reason} ->
            {:error, "grep failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_grep_output(output, "files", _head_limit) do
    files =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case String.split(line, ":", parts: 3) do
          [file, _line, _content] -> Path.relative_to(file, "/workspace")
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case files do
      [] -> {:ok, "No files matched."}
      _ -> {:ok, Enum.join(files, "\n")}
    end
  end

  defp format_grep_output(output, _lines, head_limit) do
    lines =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case String.split(line, ":", parts: 3) do
          [file, lno, content] ->
            "#{Path.relative_to(file, "/workspace")}:#{lno}: #{content}"

          _ ->
            line
        end
      end)

    truncated =
      if length(lines) >= head_limit,
        do: "\n... (truncated to #{head_limit} matches)",
        else: ""

    {:ok, Enum.join(lines, "\n") <> truncated}
  end
end
