defmodule BoomLooper.ProjectStore do
  @moduledoc """
  Persists projects to `~/.boomlooper/projects.json`.

  ```json
  {
    "version": 2,
    "projects": [
      {"path": "/Users/brad/myapp", "name": "myapp", "source_type": "local"},
      {"path": "git@github.com:acme/thing.git", "source_type": "github"}
    ]
  }
  ```

  The `path` field is overloaded: for Local projects it's a filesystem path;
  for GitHub projects it's the git URL. That's historical — new code should
  read `source_type` to decide. Records missing `source_type` are migrated
  on load (URL prefix → `github`, else → `local`).
  """

  @version 2

  @doc "Path to the projects.json file."
  def path do
    Path.join(boomlooper_home(), "projects.json")
  end

  @doc """
  Load all projects from disk. Returns a list of maps with `path`, `name`,
  `source_type`, and `source_config` keys. Legacy records without
  `source_type` are migrated inline (the file itself isn't rewritten until
  `save/1` is called).
  """
  def load do
    case File.read(path()) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"projects" => projects}} when is_list(projects) ->
            projects
            |> Enum.map(&decode_record/1)
            |> Enum.reject(&is_nil(&1.path))

          _ ->
            []
        end

      {:error, :enoent} ->
        []

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Save projects to disk. Accepts a list of paths, record maps, or mixed.
  """
  def save(projects) do
    records = Enum.map(projects, &encode_record/1)
    data = %{"version" => @version, "projects" => records}

    file_path = path()
    File.mkdir_p!(Path.dirname(file_path))
    File.write!(file_path, Jason.encode!(data, pretty: true))
  end

  @doc """
  Add a project. Idempotent — won't add duplicates. Accepts optional
  `source_type: :local | :github` and `source_config: map()`.
  """
  def add(project_path, opts \\ []) do
    source_type = Keyword.get(opts, :source_type) || infer_source_type(project_path)
    source_config = Keyword.get(opts, :source_config)

    projects = load()
    existing_paths = Enum.map(projects, & &1.path)

    if project_path in existing_paths do
      # Upgrade an existing record with source_type if it didn't have one.
      updated =
        Enum.map(projects, fn p ->
          if p.path == project_path and is_nil(p.source_type) do
            %{p | source_type: source_type, source_config: source_config}
          else
            p
          end
        end)

      if updated != projects, do: save(updated)
    else
      new_record = %{
        path: project_path,
        name: nil,
        source_type: source_type,
        source_config: source_config
      }

      save(projects ++ [new_record])
    end

    :ok
  end

  @doc "Remove a project by path (or git URL)."
  def remove(project_path) do
    projects = load() |> Enum.reject(&(&1.path == project_path))
    save(projects)
    :ok
  end

  # --- Private ---

  defp decode_record(p) when is_map(p) do
    path = p["path"]

    %{
      path: path,
      name: p["name"],
      source_type: decode_source_type(p["source_type"]) || infer_source_type(path),
      source_config: decode_config(p["source_config"])
    }
  end

  defp decode_source_type("local"), do: :local
  defp decode_source_type("github"), do: :github
  defp decode_source_type(_), do: nil

  defp decode_config(nil), do: nil
  defp decode_config(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end

  defp encode_record(p) when is_binary(p) do
    %{"path" => p, "source_type" => Atom.to_string(infer_source_type(p))}
  end

  defp encode_record(%{} = p) do
    source_type = p[:source_type] || infer_source_type(p[:path])

    %{
      "path" => p[:path],
      "name" => p[:name],
      "source_type" => source_type && Atom.to_string(source_type),
      "source_config" => encode_config(p[:source_config])
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp encode_config(nil), do: nil
  defp encode_config(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp infer_source_type(nil), do: nil
  defp infer_source_type(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "git@") -> :github
      String.starts_with?(path, "https://") -> :github
      String.starts_with?(path, "http://") -> :github
      true -> :local
    end
  end

  defp boomlooper_home do
    System.get_env("BOOMLOOPER_HOME", Path.expand("~/.boomlooper"))
  end
end
