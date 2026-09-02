defmodule Loopyard.Agents.Loader do
  @moduledoc """
  Parse an `agent.md` file — YAML frontmatter delimited by `---` lines, then a
  markdown body — into the fields a `Loopyard.Agents.Template` stamps its
  composition onto: `name` (required), `description`, `model` (optional; the
  loop supplies a default when absent), and the `body`.

  The composition itself (compute, tools, loop, context blocks) is NOT
  frontmatter today: templates are code presets (`Template.coding/0`,
  `Template.system/0`). When they become user-configurable, this is where
  those fields get parsed.
  """

  @type fields :: %{
          name: String.t(),
          description: String.t() | nil,
          model: String.t() | nil,
          body: String.t()
        }

  @doc """
  Load `<folder>/agent.md`. Returns `{:ok, fields}` or `{:error, reason}`.
  """
  @spec load(String.t()) :: {:ok, fields()} | {:error, term()}
  def load(folder) when is_binary(folder) do
    path = Path.join(folder, "agent.md")

    with {:ok, contents} <- File.read(path),
         {:ok, frontmatter, body} <- split(contents),
         {:ok, name} <- fetch_name(frontmatter),
         {:ok, model} <- fetch_model(frontmatter) do
      {:ok, %{name: name, description: frontmatter["description"], model: model, body: body}}
    end
  end

  @doc false
  def split(contents) when is_binary(contents) do
    case Regex.run(~r/\A---\n(.*?)\n---\n?(.*)\z/s, contents) do
      [_, yaml, body] ->
        case YamlElixir.read_from_string(yaml) do
          {:ok, parsed} when is_map(parsed) -> {:ok, parsed, String.trim(body)}
          {:ok, _} -> {:error, "frontmatter must be a map"}
          # YamlElixir's errors are always ParsingError/FileNotFoundError
          # structs carrying `message` — there is no other error shape.
          {:error, %{message: msg}} -> {:error, "invalid YAML: #{msg}"}
        end

      nil ->
        {:error, "missing YAML frontmatter (must start with --- line)"}
    end
  end

  defp fetch_name(%{"name" => name}) when is_binary(name) and byte_size(name) > 0, do: {:ok, name}
  defp fetch_name(_), do: {:error, "missing required frontmatter field: name"}

  # A model is a plain string the loop interprets (an id, or an alias the
  # loop knows); nil means "the loop's default".
  defp fetch_model(frontmatter) do
    case Map.get(frontmatter, "model") do
      nil -> {:ok, nil}
      model when is_binary(model) and model != "" -> {:ok, model}
      other -> {:error, "invalid model: #{inspect(other)} — expected a string"}
    end
  end
end
