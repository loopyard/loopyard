defmodule BoomLooper.Tools.Container.Grep do
  use BoomLooper.Tool,
    name: "grep",
    description: "Recursive content search inside the workspace. Returns structured matches. Excludes .git/node_modules/vendor etc. Results are paginated — use offset to page through large result sets.",
    busy_words: ["grepping", "hunting for matches", "searching"],
    params: [
      agent_id: {:string, required: true},
      pattern: {:string, required: true, description: "Text to search for. Fixed string by default — pass regex=true for extended regex."},
      path: {:string, description: "Subdirectory under /workspace to search (default: whole workspace)"},
      include: {:string, description: "File pattern to filter, e.g. '*.json' or '*.{ts,vue}'"},
      regex: {:boolean, description: "Treat pattern as extended regex (default: false)"},
      output_mode: {:string, description: "'lines' (default — file:line: content) or 'files' (just unique file paths)"},
      context_lines: {:integer, description: "Show N lines before and after each match (like grep -C). Useful to see surrounding code without a separate read_file call."},
      limit: {:integer, description: "Max matches to return (default: 50)"},
      offset: {:integer, description: "Skip this many matches (default: 0). Use for pagination."}
    ]

  alias BoomLooper.Docker
  alias BoomLooper.Tools.Container.{Helpers, Pagination}

  def execute(%{agent_id: agent_id, pattern: pattern} = params, _assigns) do
    path = Map.get(params, :path, ".") |> Helpers.normalize_search_path()
    include = Map.get(params, :include)
    regex? = Map.get(params, :regex, false)
    output_mode = Map.get(params, :output_mode, "lines")
    context_lines = Map.get(params, :context_lines)
    limit = Map.get(params, :limit, 50)
    offset = Map.get(params, :offset, 0)

    with {:ok, _} <- Helpers.validate_workspace_path(path) do
      if pattern == "" do
        {:error, "pattern must not be empty"}
      else
        grep_in_container(agent_id, pattern, path, include, regex?, output_mode, context_lines, limit, offset)
      end
    end
  end

  defp grep_in_container(agent_id, pattern, path, include, regex?, output_mode, context_lines, limit, offset) do
    case Helpers.resolve_container(agent_id) do
      {:ok, container} ->
        flags = ["-rn", "--color=never"]
        flags = if regex?, do: flags ++ ["-E"], else: flags ++ ["-F"]

        flags =
          flags ++
            ~w(
              --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=vendor
              --exclude-dir=_build --exclude-dir=deps --exclude-dir=.next
              --exclude-dir=dist --exclude-dir=target --exclude-dir=.venv
              --exclude-dir=__pycache__
            )

        flags = if include, do: flags ++ ["--include=#{include}"], else: flags
        flags = if context_lines, do: flags ++ ["-C", to_string(min(context_lines, 10))], else: flags
        full_path = Path.join("/workspace", path)

        # Fetch enough for pagination
        fetch_count = offset + limit + 1

        cmd =
          "grep #{Enum.join(flags, " ")} #{Helpers.shell_quote(pattern)} #{Helpers.shell_quote(full_path)} 2>/dev/null | head -n #{fetch_count}"

        case Docker.exec_in(container, cmd, timeout: 30_000) do
          {:ok, ""} ->
            {:ok, "No matches for #{inspect(pattern)} in #{path}"}

          {:ok, output} ->
            format_output(output, output_mode, limit, offset)

          {:error, reason} ->
            {:error, "grep failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_output(output, "files", _limit, _offset) do
    files =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case String.split(line, ":", parts: 3) do
          [file, _, _] -> Path.relative_to(file, "/workspace")
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

  defp format_output(output, _lines, limit, offset) do
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

    {:ok, Pagination.format_lines(lines, limit: limit, offset: offset)}
  end
end
