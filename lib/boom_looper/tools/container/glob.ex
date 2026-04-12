defmodule BoomLooper.Tools.Container.Glob do
  use BoomLooper.Tool,
    name: "glob",
    description: "Find files in the workspace by glob pattern (e.g. '*.json', '**/*.ts', 'app/**/*.vue'). Returns paths relative to /workspace. PREFER THIS over `exec(\"find ...\")`. Excludes the same junk dirs as `grep`.",
    params: [
      agent_id: {:string, required: true},
      pattern: {:string, required: true, description: "Glob pattern. '*' matches one segment, '**' matches any depth. Examples: '*.json', '**/*.ts', 'app/**/*.vue'"},
      path: {:string, description: "Subdirectory under /workspace to search from (default: whole workspace)"},
      head_limit: {:integer, description: "Max files to return (default: 200)"}
    ]

  alias BoomLooper.Docker
  alias BoomLooper.Tools.Container.Helpers

  def execute(%{agent_id: agent_id, pattern: pattern} = params, _assigns) do
    path = Map.get(params, :path, ".") |> Helpers.normalize_search_path()
    head_limit = Map.get(params, :head_limit, 200)

    with {:ok, _} <- Helpers.validate_workspace_path(path) do
      cond do
        pattern == "" ->
          {:error, "pattern must not be empty"}

        true ->
          glob_in_container(agent_id, pattern, path, head_limit)
      end
    end
  end

  defp glob_in_container(agent_id, pattern, path, head_limit) do
    case Helpers.resolve_container(agent_id) do
      {:ok, container} ->
        full_path = Path.join("/workspace", path)
        find_args = glob_to_find_args(pattern)

        cmd =
          "find #{Helpers.shell_quote(full_path)} -type f " <>
            "-not -path '*/.git/*' -not -path '*/node_modules/*' " <>
            "-not -path '*/vendor/bundle/*' -not -path '*/_build/*' " <>
            "-not -path '*/deps/*' -not -path '*/.next/*' " <>
            "-not -path '*/dist/*' -not -path '*/target/*' " <>
            "-not -path '*/.venv/*' -not -path '*/__pycache__/*' " <>
            "#{find_args} 2>/dev/null | head -n #{head_limit}"

        case Docker.exec_in(container, cmd, timeout: 30_000) do
          {:ok, ""} ->
            {:ok, "No files matched #{inspect(pattern)}"}

          {:ok, output} ->
            relative =
              output
              |> String.split("\n", trim: true)
              |> Enum.map(&Path.relative_to(&1, "/workspace"))

            truncated =
              if length(relative) >= head_limit,
                do: "\n... (truncated to #{head_limit} files)",
                else: ""

            {:ok, Enum.join(relative, "\n") <> truncated}

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
