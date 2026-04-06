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

  @doc "Load all projects from disk. Returns list of %{path: ..., name: ...} maps."
  def load do
    case File.read(path()) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"projects" => projects}} when is_list(projects) ->
            Enum.map(projects, fn p ->
              %{path: p["path"], name: p["name"]}
            end) |> Enum.reject(&is_nil(&1.path))

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

  @doc "Save projects to disk. Accepts list of paths (strings) or project maps."
  def save(projects) do
    records = Enum.map(projects, fn
      p when is_binary(p) -> %{"path" => p}
      %{path: path, name: name} -> %{"path" => path, "name" => name}
      %{path: path} -> %{"path" => path}
    end)
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
