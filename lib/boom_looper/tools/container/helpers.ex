defmodule BoomLooper.Tools.Container.Helpers do
  @moduledoc """
  Shared helpers used by multiple container tool modules.
  """

  alias BoomLooper.Docker
  alias BoomLooper.Workspace.ServiceManager

  @doc """
  Validate that a file path stays within /workspace.
  Rejects path traversal (../), absolute paths outside /workspace,
  and null bytes. Returns {:ok, normalized} or {:error, reason}.
  """
  def validate_workspace_path(path) when is_binary(path) do
    cond do
      String.contains?(path, <<0>>) ->
        {:error, "Path contains null bytes"}

      true ->
        normalized = Path.expand(path, "/workspace")

        if String.starts_with?(normalized, "/workspace/") or normalized == "/workspace" do
          {:ok, normalized}
        else
          {:error, "Path must be within /workspace: #{path}"}
        end
    end
  end

  def validate_workspace_path(_), do: {:error, "Path must be a string"}

  def validate_string(value, field, max_bytes) do
    cond do
      not is_binary(value) -> {:error, "#{field} must be a string"}
      byte_size(value) > max_bytes -> {:error, "#{field} exceeds #{max_bytes} byte limit"}
      String.contains?(value, <<0>>) -> {:error, "#{field} contains null bytes"}
      true -> :ok
    end
  end

  def validate_timeout(seconds) when is_number(seconds) and seconds >= 1 and seconds <= 3600, do: :ok
  def validate_timeout(_), do: {:error, "timeout must be between 1 and 3600 seconds"}

  def resolve_container(agent_id) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        container = ServiceManager.service_container_name(workspace_id, "workspace")
        {:ok, container}

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  def resolve_service_container(agent_id, service_name) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: workspace_id} when is_binary(workspace_id) ->
        container = ServiceManager.service_container_name(workspace_id, service_name)

        if Docker.container_running?(container) || container_exists?(container) do
          {:ok, container}
        else
          {:error, "Service #{service_name} not found"}
        end

      _ ->
        {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  def agent_workspace_id(agent_id) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: wid} when is_binary(wid) -> {:ok, wid}
      _ -> {:error, "Agent #{agent_id} has no workspace"}
    end
  end

  def normalize_search_path("."), do: "."
  def normalize_search_path(""), do: "."
  def normalize_search_path(path) when is_binary(path) do
    path
    |> String.trim_leading("/")
    |> String.trim_leading("./")
  end

  def shell_quote(s) when is_binary(s) do
    "'" <> String.replace(s, "'", "'\"'\"'") <> "'"
  end

  defp container_exists?(name) do
    match?({:ok, _}, Docker.docker(["inspect", "--format", "{{.Name}}", name]))
  end
end
