defmodule Loopyard.Tools.Secrets do
  @moduledoc """
  MCP tools for secret management.

  Secrets are scoped to the calling agent's workspace and project —
  see `Loopyard.Secrets`. An agent can only list/get secrets that
  are either global (no scope) or explicitly scoped to its own
  workspace_id / project_id.

  Built on our own `Loopyard.Tool` macro (NOT the claude_code SDK's tool DSL),
  so it's insulated from SDK churn. The agent's `agent_id` arrives as a param
  and is authorized against the runtime-bound id by `Loopyard.Tool`'s
  `@before_compile` (same model as the container tools) before scope is resolved.
  """
  alias Loopyard.Secrets

  defmodule ListSecrets do
    use Loopyard.Tool,
      name: "list_secrets",
      description:
        "List available secret names and keys (not values). Only secrets scoped to your workspace/project (or global secrets) are visible — the user may have project-specific credentials that won't appear here.",
      params: [agent_id: {:string, required: true}]

    def execute(%{agent_id: agent_id}, _assigns) do
      {ws_id, proj_id} = Loopyard.Tools.Secrets.resolve_scope(agent_id)
      {:ok, Loopyard.Tools.Secrets.do_list_secrets(ws_id, proj_id)}
    end
  end

  defmodule GetSecret do
    use Loopyard.Tool,
      name: "get_secret",
      description:
        "Get a secret value by key. Only returns secrets scoped to your workspace/project (or global ones). Scoped secrets belonging to other projects are indistinguishable from a missing key.",
      params: [
        agent_id: {:string, required: true},
        key: {:string, required: true, description: "The secret key (e.g. 'github_token')"}
      ]

    def execute(%{agent_id: agent_id, key: key}, _assigns) do
      {ws_id, proj_id} = Loopyard.Tools.Secrets.resolve_scope(agent_id)
      Loopyard.Tools.Secrets.do_get_secret(key, ws_id, proj_id)
    end
  end

  @tools [ListSecrets, GetSecret]

  @doc "MCP server descriptor — name + the list of tool modules."
  def __tool_server__, do: %{name: "loopyard-secrets", tools: @tools}

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

  @doc "Resolve the {workspace_id, project_id} scope for an agent."
  def resolve_scope(agent_id) when is_binary(agent_id) do
    workspace_id = agent_workspace_id(agent_id)
    project_id = workspace_id && agent_project_id(workspace_id)
    {workspace_id, project_id}
  end

  def resolve_scope(_), do: {nil, nil}

  defp agent_workspace_id(agent_id) do
    case Loopyard.ChatAgent.get_state(agent_id) do
      %{workspace_id: wid} when is_binary(wid) -> wid
      _ -> nil
    end
  end

  defp agent_project_id(workspace_id) do
    case Loopyard.ProjectRegistry.get_workspace(workspace_id) do
      %{project_id: pid} when is_binary(pid) -> pid
      _ -> nil
    end
  end
end
