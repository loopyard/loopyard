defmodule BoomLooper.Checklist do
  @moduledoc """
  Struct and operations for GitHub-style markdown checklists.

  A checklist is a plain markdown file with `- [ ]` / `- [x]` items.
  The file IS the state — checking items updates the file directly.
  """

  defstruct [:id, :name, :description, :items, :source_path, :active_path, :raw]

  @type item :: %{text: String.t(), checked: boolean(), line: pos_integer()}

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          description: String.t() | nil,
          items: [item()],
          source_path: String.t() | nil,
          active_path: String.t() | nil,
          raw: String.t() | nil
        }

  @builtin_dir "priv/checklists"
  @project_dir ".hive/checklists"
  @active_dir ".hive/active"

  @doc "Parse markdown content into a Checklist struct"
  def parse(markdown) when is_binary(markdown) do
    lines = String.split(markdown, "\n")

    name = extract_title(lines)
    description = extract_description(lines)
    items = extract_items(lines)

    %__MODULE__{
      name: name,
      description: description,
      items: items,
      raw: markdown
    }
  end

  @doc "Load a checklist from a file path"
  def load_file(path) do
    case File.read(path) do
      {:ok, content} ->
        checklist =
          parse(content)
          |> Map.put(:source_path, path)
          |> Map.put(:id, Path.basename(path, ".md"))

        {:ok, checklist}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "List available checklists (built-in + project-specific)"
  def available(project_dir \\ nil) do
    builtin = load_from_dir(builtin_dir())
    project = if project_dir, do: load_from_dir(Path.join(project_dir, @project_dir)), else: []

    # Project checklists override built-in ones with the same ID
    builtin_ids = MapSet.new(Enum.map(project, & &1.id))

    filtered_builtin =
      Enum.reject(builtin, fn c -> MapSet.member?(builtin_ids, c.id) end)

    filtered_builtin ++ project
  end

  @doc "Copy a checklist template to the active directory for an agent"
  def instantiate(%__MODULE__{} = checklist, agent_id, project_dir) do
    active_dir = Path.join(project_dir, @active_dir)
    File.mkdir_p!(active_dir)

    filename = "#{agent_id}-#{checklist.id}.md"
    active_path = Path.join(active_dir, filename)

    File.write!(active_path, checklist.raw)

    %{checklist | active_path: active_path}
  end

  @doc "Instantiate a checklist by ID for an agent"
  def instantiate_by_id(checklist_id, agent_id, project_dir) do
    checklists = available(project_dir)

    case Enum.find(checklists, &(&1.id == checklist_id)) do
      nil -> {:error, :not_found}
      checklist ->
        {:ok, instantiate(checklist, agent_id, project_dir)}
    end
  end

  @doc "Check an item at a given line number (1-based)"
  def check_item(path, line) do
    update_item(path, line, &String.replace(&1, "- [ ]", "- [x]", global: false))
  end

  @doc "Uncheck an item at a given line number (1-based)"
  def uncheck_item(path, line) do
    update_item(path, line, &String.replace(&1, "- [x]", "- [ ]", global: false))
  end

  @doc "Get progress as {checked, total}"
  def progress(%__MODULE__{items: items}) do
    checked = Enum.count(items, & &1.checked)
    {checked, length(items)}
  end

  @doc "Get progress from a file path"
  def progress_from_file(path) do
    case load_file(path) do
      {:ok, checklist} -> {:ok, progress(checklist)}
      error -> error
    end
  end

  @doc "Read and return current items from an active checklist file"
  def read_items(path) do
    case load_file(path) do
      {:ok, checklist} -> {:ok, checklist.items}
      error -> error
    end
  end

  @doc "Returns the built-in checklists directory path"
  def builtin_dir do
    Application.app_dir(:boom_looper, @builtin_dir)
  end

  # --- Private ---

  defp extract_title(lines) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/^#\s+(.+)$/, String.trim(line)) do
        [_, title] -> String.trim(title)
        nil -> nil
      end
    end)
  end

  defp extract_description(lines) do
    # Description is the first non-empty, non-heading paragraph after the title
    lines
    |> Enum.drop_while(fn line -> !Regex.match?(~r/^#\s+/, String.trim(line)) end)
    |> Enum.drop(1)
    |> Enum.drop_while(fn line -> String.trim(line) == "" end)
    |> Enum.take_while(fn line ->
      trimmed = String.trim(line)
      trimmed != "" && !String.starts_with?(trimmed, "#") && !String.starts_with?(trimmed, "- [")
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.join(" ")
    |> case do
      "" -> nil
      desc -> desc
    end
  end

  defp extract_items(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _idx} ->
      trimmed = String.trim(line)
      String.starts_with?(trimmed, "- [ ]") || String.starts_with?(trimmed, "- [x]")
    end)
    |> Enum.map(fn {line, idx} ->
      trimmed = String.trim(line)
      checked = String.starts_with?(trimmed, "- [x]")

      text =
        trimmed
        |> String.replace(~r/^- \[[ x]\]\s*/, "")
        |> String.trim()

      %{text: text, checked: checked, line: idx}
    end)
  end

  defp update_item(path, line, transform_fn) when is_integer(line) and line > 0 do
    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        if line <= length(lines) do
          updated_lines =
            List.update_at(lines, line - 1, transform_fn)

          File.write!(path, Enum.join(updated_lines, "\n"))
          :ok
        else
          {:error, :line_out_of_range}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_from_dir(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.flat_map(fn file ->
          case load_file(Path.join(dir, file)) do
            {:ok, checklist} -> [checklist]
            _ -> []
          end
        end)

      {:error, _} ->
        []
    end
  end
end
