defmodule Loopyard.Tools.AgentFiles.ReadAgentFile do
  @moduledoc """
  Read a file from the calling agent's own template folder
  (`Loopyard.Agents.Template.folder/1`, resolved from the agent's
  `template_id`). Paths are validated to stay within that folder — no `..`
  escape, no absolute paths.
  """

  use Loopyard.Tool,
    name: "read_agent_file",
    description:
      "Read a file from your agent definition folder (setup_guide.md, stack templates, etc.). Path is relative to the agent folder.",
    params: [
      agent_id: {:string, required: true},
      path: {:string, required: true, description: "Relative path inside the agent folder"}
    ]

  alias Loopyard.Agents.Template

  @max_bytes 200_000

  def execute(%{path: path} = params, _assigns) do
    folder = Template.folder(template_id(params[:agent_id]))

    with {:ok, abs_path} <- validate_path(folder, path),
         {:ok, contents} <- read_file(abs_path) do
      {:ok, contents}
    end
  end

  # The agent's template, from its ETS summary (never a GenServer call —
  # this runs mid-turn); an agent without one is a coding agent.
  defp template_id(agent_id) when is_binary(agent_id) do
    case :ets.lookup(:chat_agents, agent_id) do
      [{^agent_id, %{template_id: id}}] when is_binary(id) ->
        if Template.exists?(id), do: id, else: "coding"

      _ ->
        "coding"
    end
  rescue
    _ -> "coding"
  end

  defp template_id(_), do: "coding"

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
