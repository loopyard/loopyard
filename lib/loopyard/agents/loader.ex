defmodule Loopyard.Agents.Loader do
  @moduledoc """
  Parse an `agent.md` file into a `Loopyard.Agents.Agent` struct.

  The file format is YAML frontmatter delimited by `---` lines, followed
  by a markdown body. Frontmatter fields are all optional except `name`;
  missing fields use sensible defaults.
  """

  alias Loopyard.Agents.Agent

  @valid_models ~w(opus sonnet haiku)

  @doc """
  Load an agent from a folder. The folder must contain `agent.md`.
  Returns `{:ok, %Agent{}}` or `{:error, reason}`.
  """
  def load(folder) when is_binary(folder) do
    path = Path.join(folder, "agent.md")

    with {:ok, contents} <- File.read(path),
         {:ok, frontmatter, body} <- split(contents),
         {:ok, agent} <- build(frontmatter, body, folder) do
      {:ok, agent}
    end
  end

  @doc false
  def split(contents) when is_binary(contents) do
    case Regex.run(~r/\A---\n(.*?)\n---\n?(.*)\z/s, contents) do
      [_, yaml, body] ->
        case YamlElixir.read_from_string(yaml) do
          {:ok, parsed} when is_map(parsed) -> {:ok, parsed, String.trim(body)}
          {:ok, _} -> {:error, "frontmatter must be a map"}
          {:error, %{message: msg}} -> {:error, "invalid YAML: #{msg}"}
          {:error, reason} -> {:error, "invalid YAML: #{inspect(reason)}"}
        end

      nil ->
        {:error, "missing YAML frontmatter (must start with --- line)"}
    end
  end

  defp build(frontmatter, body, folder) do
    with {:ok, name} <- fetch_name(frontmatter),
         {:ok, model} <- fetch_model(frontmatter) do
      agent = %Agent{
        name: name,
        description: frontmatter["description"],
        model: model,
        tools: list_field(frontmatter, "tools"),
        disallowed_tools: list_field(frontmatter, "disallowed_tools"),
        gates: Map.get(frontmatter, "gates", %{}) || %{},
        body: body,
        folder: folder
      }

      {:ok, agent}
    end
  end

  defp fetch_name(%{"name" => name}) when is_binary(name) and byte_size(name) > 0, do: {:ok, name}
  defp fetch_name(_), do: {:error, "missing required frontmatter field: name"}

  defp fetch_model(frontmatter) do
    case Map.get(frontmatter, "model", "sonnet") do
      model when model in @valid_models ->
        {:ok, model}

      other ->
        {:error,
         "invalid model alias: #{inspect(other)} — expected one of #{inspect(@valid_models)}"}
    end
  end

  defp list_field(frontmatter, key) do
    case Map.get(frontmatter, key, []) do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      nil -> []
      _other -> []
    end
  end
end
