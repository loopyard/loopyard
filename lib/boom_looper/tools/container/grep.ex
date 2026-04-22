defmodule BoomLooper.Tools.Container.Grep do
  use BoomLooper.Tool,
    name: "grep",
    description: "Recursive content search inside the workspace. Returns structured matches. Excludes .git/node_modules/vendor etc. Results are paginated — use offset to page through large result sets.",
    params: [
      agent_id: {:string, required: true},
      pattern: {:string, required: true, description: "Text to search for. Fixed string by default — pass regex=true for extended regex."},
      path: {:string, description: "Subdirectory under /workspace to search (default: whole workspace)"},
      include: {:string, description: "File pattern to filter, e.g. '*.json' or '*.{ts,vue}'"},
      regex: {:boolean, description: "Treat pattern as extended regex (default: false)"},
      output_mode: {:string, description: "'lines' (default — file:line: content) or 'files' (just unique file paths)"},
      limit: {:integer, description: "Max matches to return (default: 50, max: 200)"},
      offset: {:integer, description: "Skip this many matches before returning (default: 0). Use for pagination."}
    ]

  alias BoomLooper.Docker
  alias BoomLooper.Tools.Container.Helpers

  # Hard cap on output chars to prevent context blowout.
  # 50 matches × ~150 chars avg = ~7500 chars. This cap catches
  # the pathological case (minified files, long lines).
  @max_output_chars 8_000

  def execute(%{agent_id: agent_id, pattern: pattern} = params, _assigns) do
    path = Map.get(params, :path, ".") |> Helpers.normalize_search_path()
    include = Map.get(params, :include)
    regex? = Map.get(params, :regex, false)
    output_mode = Map.get(params, :output_mode, "lines")
    limit = Map.get(params, :limit, 50) |> min(200)
    offset = Map.get(params, :offset, 0) |> max(0)

    with {:ok, _} <- Helpers.validate_workspace_path(path) do
      if pattern == "" do
        {:error, "pattern must not be empty"}
      else
        grep_in_container(agent_id, pattern, path, include, regex?, output_mode, limit, offset)
      end
    end
  end

  defp grep_in_container(agent_id, pattern, path, include, regex?, output_mode, limit, offset) do
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

        full_path = Path.join("/workspace", path)

        # Fetch offset+limit+1 to know if there are more results
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

  defp format_output(output, _lines, limit, offset) do
    all_lines =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case String.split(line, ":", parts: 3) do
          [file, lno, content] ->
            "#{Path.relative_to(file, "/workspace")}:#{lno}: #{String.slice(content, 0..200)}"

          _ ->
            String.slice(line, 0..200)
        end
      end)

    total = length(all_lines)
    page = Enum.slice(all_lines, offset, limit)
    has_more = total > offset + limit

    result = Enum.join(page, "\n")

    # Hard cap on output size
    result =
      if String.length(result) > @max_output_chars do
        String.slice(result, 0, @max_output_chars) <> "\n... (output truncated at #{@max_output_chars} chars)"
      else
        result
      end

    footer = cond do
      has_more && offset > 0 ->
        "\n\n(showing matches #{offset + 1}-#{offset + length(page)} of #{total}+. Use offset=#{offset + limit} for next page)"
      has_more ->
        "\n\n(showing first #{length(page)} matches of #{total}+. Use offset=#{limit} for next page)"
      offset > 0 ->
        "\n\n(showing matches #{offset + 1}-#{offset + length(page)})"
      true ->
        ""
    end

    {:ok, result <> footer}
  end
end
