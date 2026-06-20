defmodule Loopyard.Tools.AgentFiles.ReadAgentFile do
  @moduledoc """
  Read a file from the agent's own definition folder
  (`Loopyard.Agents.Coding.folder/0`). Paths are validated to stay within
  that folder — no `..` escape, no absolute paths.
  """

  use Loopyard.Tool,
    name: "read_agent_file",
    description:
      "Read a file from your agent definition folder (setup_guide.md, stack templates, etc.). Path is relative to the agent folder.",
    params: [
      agent_id: {:string, required: true},
      path: {:string, required: true, description: "Relative path inside the agent folder"}
    ]

  alias Loopyard.Agents.Coding

  @max_bytes 200_000

  def execute(%{path: path}, _assigns) do
    folder = Coding.folder()

    with {:ok, abs_path} <- validate_path(folder, path),
         {:ok, contents} <- read_file(abs_path) do
      {:ok, contents}
    end
  end

  defp validate_path(folder, path) when is_binary(path) do
    cond do
      String.contains?(path, <<0>>) ->
        {:error, "Path contains null bytes"}

      String.starts_with?(path, "/") ->
        {:error, "Path must be relative to the agent folder"}

      true ->
        abs = Path.expand(path, folder)

        if String.starts_with?(abs, folder <> "/") or abs == folder do
          {:ok, abs}
        else
          {:error, "Path escapes the agent folder: #{path}"}
        end
    end
  end

  defp validate_path(_, _), do: {:error, "Path must be a string"}

  defp read_file(abs_path) do
    case File.stat(abs_path) do
      {:ok, %{type: :regular, size: size}} when size <= @max_bytes ->
        File.read(abs_path)

      {:ok, %{type: :regular, size: size}} ->
        {:error, "File too large (#{size} bytes, max #{@max_bytes})"}

      {:ok, %{type: other}} ->
        {:error, "Not a regular file: #{other}"}

      {:error, :enoent} ->
        {:error, "File not found"}

      {:error, reason} ->
        {:error, "Cannot read file: #{inspect(reason)}"}
    end
  end
end
