defmodule BoomLooper.Tools.Container.Glob do
  use BoomLooper.Tool,
    name: "glob",
    description:
      "Find files in the workspace by glob pattern (e.g. '*.json', '**/*.ts', 'app/**/*.vue'). Returns paths relative to /workspace. PREFER THIS over `exec(\"find ...\")`. Excludes the same junk dirs as `grep`.",
    busy_words: ["finding files", "globbing", "scouting"],
    params: [
      agent_id: {:string, required: true},
      pattern:
        {:string,
         required: true,
         description:
           "Glob pattern. '*' matches one segment, '**' matches any depth. Examples: '*.json', '**/*.ts', 'app/**/*.vue'"},
      path:
        {:string,
         description: "Subdirectory under /workspace to search from (default: whole workspace)"},
      limit: {:integer, description: "Max files to return (default: 100)"},
      offset: {:integer, description: "Skip this many files (for pagination, default: 0)"}
    ]

  alias BoomLooper.Docker
  alias BoomLooper.Tools.Container.{Helpers, Pagination}

  def execute(%{agent_id: agent_id, pattern: pattern} = params, _assigns) do
    path = Map.get(params, :path, ".") |> Helpers.normalize_search_path()
    limit = Map.get(params, :limit, 100) |> min(500)
    offset = Map.get(params, :offset, 0) |> max(0)

    with {:ok, _} <- Helpers.validate_workspace_path(path) do
      if pattern == "" do
        {:error, "pattern must not be empty"}
      else
        glob_in_container(agent_id, pattern, path, limit, offset)
      end
    end
  end

  defp glob_in_container(agent_id, pattern, path, limit, offset) do
    case Helpers.resolve_container(agent_id) do
      {:ok, container} ->
        full_path = Path.join("/workspace", path)
        find_args = glob_to_find_args(pattern)
        fetch_count = offset + limit + 1

        cmd =
          "find #{Helpers.shell_quote(full_path)} -type f " <>
            "-not -path '*/.git/*' -not -path '*/node_modules/*' " <>
            "-not -path '*/vendor/bundle/*' -not -path '*/_build/*' " <>
            "-not -path '*/deps/*' -not -path '*/.next/*' " <>
            "-not -path '*/dist/*' -not -path '*/target/*' " <>
            "-not -path '*/.venv/*' -not -path '*/__pycache__/*' " <>
            "#{find_args} 2>/dev/null | sort | head -n #{fetch_count}"

        case Docker.exec_in(container, cmd, timeout: 30_000) do
          {:ok, ""} ->
            {:ok, "No files matched #{inspect(pattern)}"}

          {:ok, output} ->
            files =
              output
              |> String.split("\n", trim: true)
              |> Enum.map(&Path.relative_to(&1, "/workspace"))

            {page, footer} = Pagination.paginate(files, limit: limit, offset: offset)
            result = Enum.join(page, "\n")
            {:ok, if(footer, do: result <> "\n\n" <> footer, else: result)}

          {:error, reason} ->
            {:error, "find failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Translate a glob pattern into find arguments.
  defp glob_to_find_args(pattern) do
    cond do
      String.starts_with?(pattern, "**/") ->
        leaf = String.replace_prefix(pattern, "**/", "")

        if String.contains?(leaf, "/") do
          "-path #{Helpers.shell_quote("*/#{leaf}")}"
        else
          "-name #{Helpers.shell_quote(leaf)}"
        end

      String.contains?(pattern, "/**") ->
        case String.split(pattern, "/**") do
          [prefix, "/" <> leaf] when leaf != "" ->
            if String.contains?(leaf, "/") do
              "-path #{Helpers.shell_quote("*/#{prefix}/*/#{leaf}")}"
            else
              "-path #{Helpers.shell_quote("*/#{prefix}/*")} -name #{Helpers.shell_quote(leaf)}"
            end

          [prefix, ""] ->
            "-path #{Helpers.shell_quote("*/#{prefix}/*")}"

          _ ->
            "-name #{Helpers.shell_quote(pattern)}"
        end

      String.contains?(pattern, "/") ->
        "-path #{Helpers.shell_quote("*/#{pattern}")}"

      true ->
        "-name #{Helpers.shell_quote(pattern)}"
    end
  end
end
