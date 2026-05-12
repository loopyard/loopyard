defmodule Loopyard.Tools.Container.Tree do
  use Loopyard.Tool,
    name: "tree",
    description:
      "Print a directory tree from inside the workspace. ONE call gives spatial awareness of the whole project — file types, sizes, hierarchy. PREFER THIS over `exec(\"ls -la\")` or `exec(\"find ...\")` for discovery. Auto-excludes .git, node_modules, vendor/bundle, _build, deps, .next, dist, target, .venv, __pycache__.",
    busy_words: ["mapping the codebase", "surveying", "exploring"],
    params: [
      agent_id: {:string, required: true},
      path: {:string, description: "Subdirectory under /workspace (default: whole workspace)"},
      depth: {:integer, description: "Max depth to descend (default: 3, max: 8)"},
      max_entries: {:integer, description: "Max entries to print (default: 200)"}
    ]

  alias Loopyard.Docker
  alias Loopyard.Tools.Container.Helpers

  def execute(%{agent_id: agent_id} = params, _assigns) do
    path = params |> Map.get(:path, ".") |> Helpers.normalize_search_path()
    depth = Map.get(params, :depth, 3)
    max_entries = Map.get(params, :max_entries, 200)

    with {:ok, _} <- Helpers.validate_workspace_path(path) do
      cond do
        depth < 1 or depth > 8 ->
          {:error, "depth must be between 1 and 8"}

        true ->
          tree_in_container(agent_id, path, depth, max_entries)
      end
    end
  end

  defp tree_in_container(agent_id, path, depth, max_entries) do
    case Helpers.resolve_container(agent_id) do
      {:ok, container} ->
        full_path = Path.join("/workspace", path)

        cmd =
          "find #{Helpers.shell_quote(full_path)} -mindepth 1 -maxdepth #{depth} " <>
            "-not -path '*/.git*' -not -path '*/node_modules*' " <>
            "-not -path '*/vendor/bundle*' -not -path '*/_build*' " <>
            "-not -path '*/deps*' -not -path '*/.next*' " <>
            "-not -path '*/dist*' -not -path '*/target*' " <>
            "-not -path '*/.venv*' -not -path '*/__pycache__*' " <>
            "-printf '%y\\t%s\\t%P\\n' 2>/dev/null | head -n #{max_entries + 1}"

        case Docker.exec_in(container, cmd, timeout: 30_000) do
          {:ok, ""} ->
            {:ok, "(empty: #{path})"}

          {:ok, output} ->
            entries = parse_find_output(output)
            truncated = length(entries) > max_entries
            entries = Enum.take(entries, max_entries)
            {:ok, render_tree(entries, path, truncated, max_entries)}

          {:error, reason} ->
            {:error, "tree failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_find_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(line, "\t", parts: 3) do
        [type, size, path] -> {type, size, path}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp render_tree(entries, root_label, truncated, max_entries) do
    rendered =
      entries
      |> Enum.map(fn {type, size, rel_path} ->
        depth = (rel_path |> Path.split() |> length()) - 1
        indent = String.duplicate("  ", depth)
        name = Path.basename(rel_path)

        case type do
          "d" -> "#{indent}#{name}/"
          "f" -> "#{indent}#{name}  (#{format_size(size)})"
          "l" -> "#{indent}#{name} -> (link)"
          _ -> "#{indent}#{name}"
        end
      end)
      |> Enum.join("\n")

    truncation_note =
      if truncated do
        "\n\n... truncated to #{max_entries} entries. Pass max_entries to see more, or path/depth to narrow."
      else
        ""
      end

    "#{root_label}/\n#{rendered}#{truncation_note}"
  end

  defp format_size(size) when is_binary(size) do
    case Integer.parse(size) do
      {n, _} -> format_size(n)
      _ -> size
    end
  end

  defp format_size(n) when is_integer(n) and n < 1024, do: "#{n} B"
  defp format_size(n) when is_integer(n) and n < 1_048_576, do: "#{Float.round(n / 1024, 1)} KB"

  defp format_size(n) when is_integer(n) and n < 1_073_741_824,
    do: "#{Float.round(n / 1_048_576, 1)} MB"

  defp format_size(n) when is_integer(n), do: "#{Float.round(n / 1_073_741_824, 1)} GB"
  defp format_size(_), do: "?"
end
