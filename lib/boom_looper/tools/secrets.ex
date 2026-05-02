defmodule BoomLooper.Tools.Secrets do
  @moduledoc """
  MCP tool server for secret management.

  Secrets are scoped to the calling agent's workspace and project —
  see `BoomLooper.Secrets`. An agent can only list/get secrets that
  are either global (no scope) or explicitly scoped to its own
  workspace_id / project_id.
  """
  use ClaudeCode.MCP.Server, name: "boom-looper-secrets"

  alias BoomLooper.Secrets

  # --- Public API ---

  @doc false
  def do_list_secrets(workspace_id, project_id) do
    Secrets.list(workspace_id, project_id)
  end

  @doc false
  def do_get_secret(key, workspace_id, project_id) do
    case Secrets.get(key, workspace_id, project_id) do
      {:ok, value} ->
        {:ok, %{key: key, value: value}}

      :not_found ->
        {:error, "Secret '#{key}' not found. Use list_secrets to see available secrets."}
    end
  end

  # --- Tool definitions ---

  tool :list_secrets,
       "List available secret names and keys (not values). Only secrets scoped to your workspace/project (or global secrets) are visible — the user may have project-specific credentials that won't appear here." do
    def execute(_params, assigns) do
      {ws_id, proj_id} = BoomLooper.Tools.Secrets.resolve_scope(assigns)
      {:ok, BoomLooper.Tools.Secrets.do_list_secrets(ws_id, proj_id)}
    end
  end

  tool :get_secret,
       "Get a secret value by key. Only returns secrets scoped to your workspace/project (or global ones). Scoped secrets belonging to other projects are indistinguishable from a missing key." do
    field(:key, :string, required: true, description: "The secret key (e.g. 'github_token')")

    def execute(%{key: key}, assigns) do
      {ws_id, proj_id} = BoomLooper.Tools.Secrets.resolve_scope(assigns)
      BoomLooper.Tools.Secrets.do_get_secret(key, ws_id, proj_id)
    end
  end

  @doc false
  def resolve_scope(assigns) do
    workspace_id = assigns[:agent_id] && agent_workspace_id(assigns[:agent_id])
    project_id = workspace_id && agent_project_id(workspace_id)
    {workspace_id, project_id}
  end

  defp agent_workspace_id(agent_id) do
    case BoomLooper.ChatAgent.get_state(agent_id) do
      %{workspace_id: wid} when is_binary(wid) -> wid
      _ -> nil
    end
  end

  defp agent_project_id(workspace_id) do
    case BoomLooper.ProjectRegistry.get_workspace(workspace_id) do
      %{project_id: pid} when is_binary(pid) -> pid
      _ -> nil
    end
  end
end
