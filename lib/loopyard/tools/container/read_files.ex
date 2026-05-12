defmodule Loopyard.Tools.Container.ReadFiles do
  use Loopyard.Tool,
    name: "read_files",
    description:
      "Read several files in ONE round trip. PREFER THIS over multiple `read_file` calls during discovery (e.g. reading Gemfile + package.json + README + Procfile.dev at once). Files that don't exist show up as `(error: ...)` so partial failures don't lose the rest.",
    busy_words: ["speed-reading", "devouring files", "binge-reading"],
    params: [
      agent_id: {:string, required: true},
      paths:
        {:string,
         required: true,
         description:
           "JSON array of file paths relative to /workspace, e.g. '[\"Gemfile\", \"package.json\", \"README.md\"]'"}
    ]

  alias Loopyard.Tools.Container.{Helpers, ReadFile}

  def execute(%{agent_id: agent_id, paths: paths}, _assigns) do
    case Jason.decode(to_string(paths)) do
      {:ok, list} when is_list(list) ->
        read_multiple(agent_id, list)

      {:ok, _} ->
        {:error, "paths must be a JSON array of strings"}

      {:error, reason} ->
        {:error, "paths is not valid JSON: #{inspect(reason)}"}
    end
  end

  defp read_multiple(agent_id, paths) do
    cond do
      paths == [] ->
        {:error, "paths list must not be empty"}

      length(paths) > 20 ->
        {:error, "Too many paths (max 20). Read in batches if you really need more."}

      Enum.any?(paths, &(not is_binary(&1))) ->
        {:error, "all paths must be strings"}

      true ->
        results =
          Enum.map(paths, fn path ->
            case ReadFile.execute(%{agent_id: agent_id, path: path}, %{}) do
              {:ok, content} -> {path, {:ok, content}}
              {:error, reason} -> {path, {:error, reason}}
            end
          end)

        {:ok, Helpers.truncate_for_agent(format_multi_read(results), max: 32_000)}
    end
  end

  defp format_multi_read(results) do
    results
    |> Enum.map(fn
      {path, {:ok, content}} ->
        "=== #{path} (#{byte_size(content)} bytes) ===\n#{content}"

      {path, {:error, reason}} ->
        "=== #{path} (error) ===\n(#{inspect(reason)})"
    end)
    |> Enum.join("\n\n")
  end
end
