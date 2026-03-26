defmodule BoomLooper.ProjectStore do
  @moduledoc """
  Persists project paths to ~/.boomlooper/projects.json.

  Simple JSON file with project records for future extensibility:
  ```json
  {
    "version": 1,
    "projects": [
      {"path": "/Users/brad/myapp"},
      {"path": "/Users/brad/other"}
    ]
  }
  ```

  On startup, `ProjectRegistry.restore/0` loads these paths and re-registers
  them. ServiceManager then reconnects to any running containers.
  """

  @version 1

  @doc "Path to the projects.json file."
  def path do
    Path.join(boomlooper_home(), "projects.json")
  end

  @doc "Load all project paths from disk."
  def load do
    case File.read(path()) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"projects" => projects}} when is_list(projects) ->
            Enum.map(projects, & &1["path"]) |> Enum.reject(&is_nil/1)

          _ ->
            []
        end

      {:error, :enoent} ->
        []

      {:error, _reason} ->
        # Permission errors, path issues, etc. — treat as empty
        []
    end
  end

  @doc "Save project paths to disk."
  def save(project_paths) do
    records = Enum.map(project_paths, &%{"path" => &1})
    data = %{"version" => @version, "projects" => records}

    file_path = path()
    File.mkdir_p!(Path.dirname(file_path))
    File.write!(file_path, Jason.encode!(data, pretty: true))
  end

  @doc "Add a project path. Idempotent - won't add duplicates."
  def add(project_path) do
    paths = load()

    unless project_path in paths do
      save(paths ++ [project_path])
    end

    :ok
  end

  @doc "Remove a project path."
  def remove(project_path) do
    paths = load() |> Enum.reject(&(&1 == project_path))
    save(paths)
    :ok
  end

  defp boomlooper_home do
    System.get_env("BOOMLOOPER_HOME", Path.expand("~/.boomlooper"))
  end
end
