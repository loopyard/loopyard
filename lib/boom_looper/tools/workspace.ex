defmodule BoomLooper.Tools.Workspace do
  @moduledoc """
  MCP tools for workspace METADATA only (project name, system prompt).

  Infrastructure (Dockerfile, docker-compose.yml) is written directly via
  boom-looper-container tools (write_file, docker_compose). This module
  does NOT handle infrastructure — only metadata that persists in workspace.json.
  """
  use ClaudeCode.MCP.Server, name: "boom-looper-workspace"

  alias BoomLooper.Workspace

  # --- Tool definitions ---

  tool :set_workspace_name, "Set the project name. Pick something a human will recognize and that doesn't collide with other projects (a numeric suffix is appended on collision). This is what shows up in the project list." do
    field :agent_id, :string, required: true
    field :name, :string, required: true

    def execute(%{agent_id: agent_id, name: name}) do
      BoomLooper.Tools.Workspace.do_set_project_name(agent_id, name)
    end
  end

  tool :set_system_prompt, "Set a system prompt fragment that future agents will see when working on this project." do
    field :agent_id, :string, required: true
    field :system_prompt, :string, required: true

    def execute(%{agent_id: agent_id, system_prompt: prompt}) do
      BoomLooper.Tools.Workspace.do_update_config(agent_id, fn ws ->
        %{ws | system_prompt: prompt}
      end, "Wrote system prompt to workspace config. Future agents will see this.")
    end
  end

  # --- Public helpers ---

  @doc false
  def do_set_project_name(agent_id, name) do
    workspace_id = find_workspace_id(agent_id)

    case workspace_id && BoomLooper.ProjectRegistry.get_workspace(workspace_id) do
      %{project_id: project_id} ->
        with {:ok, project} <- BoomLooper.ProjectRegistry.rename_project(project_id, name) do
          do_update_config(agent_id, fn ws -> %{ws | name: project.name} end,
            "Set project name to \"#{project.name}\". This is now what appears in the project list.")
        else
          {:error, :empty_name} -> {:error, "Project name can't be empty"}
          {:error, :not_found} -> {:error, "Project not found for agent #{agent_id}"}
          {:error, reason} -> {:error, "Failed to rename project: #{inspect(reason)}"}
        end

      _ ->
        do_update_config(agent_id, fn ws -> %{ws | name: name} end,
          "Set workspace name to \"#{name}\" in config.")
    end
  end

  @doc false
  def do_update_config(agent_id, update_fn, success_msg) do
    workspace_id = find_workspace_id(agent_id)

    if workspace_id do
      volume_name = case BoomLooper.ProjectRegistry.get_workspace(workspace_id) do
        %{volume: vol} when is_binary(vol) -> vol
        _ -> "code-#{workspace_id}"
      end

      ws = case Workspace.load_from_volume(volume_name) do
        {:ok, existing} -> existing
        _ -> %Workspace{}
      end

      updated = update_fn.(ws)

      case Workspace.save_to_volume(volume_name, updated) do
        :ok -> {:ok, success_msg}
        {:error, reason} -> {:error, "Failed to save config: #{inspect(reason)}"}
      end
    else
      {:error, "Agent #{agent_id} has no workspace — cannot update config"}
    end
  end

  # --- Private ---


  defp find_workspace_id(agent_id) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: ws_id} when is_binary(ws_id) -> ws_id
      _ -> nil
    end
  end
end
