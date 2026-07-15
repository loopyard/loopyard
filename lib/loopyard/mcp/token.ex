defmodule Loopyard.MCP.Token do
  @moduledoc """
  Per-agent scoped bearer tokens for the ACP MCP bridge
  (`LoopyardWeb.MCP.Server`).

  An in-container ACP harness can't use the in-process Elixir MCP servers the
  ClaudeCode backend uses — it reaches Loopyard's control-plane tools over HTTP
  instead. This token is what binds one of those HTTP sessions to a single
  agent's identity: the container presents `Authorization: Bearer <token>`, the
  plug verifies it, and every tool call runs as `{agent_id, workspace_id}` —
  never a caller-supplied id.

  Signed with the endpoint's `secret_key_base` (`Phoenix.Token`), so it needs no
  server-side storage and can't be forged without the secret. The identity is
  baked into the token, so a leaked token is scoped to exactly one agent's own
  workspace — the same boundary `Loopyard.Tool.authorize_agent/2` enforces for
  the in-process path.

  This is the network edge of the workspace-agent sandbox boundary. Keep the
  claims minimal (`agent_id` + `workspace_id`) and NEVER widen the scope encoded
  here — see docs/SECURITY.md.
  """

  @salt "acp mcp bearer v1"
  # Agents are long-lived (idle-reaped after hours, resumed across restarts). A
  # generous max_age keeps a resumed agent's token valid without a re-mint dance;
  # the token is still scoped to one agent, so age is not the security boundary.
  @max_age_seconds 60 * 60 * 24 * 30

  @doc """
  Sign a token binding this MCP session to one agent + its workspace.
  Returns the opaque token string.
  """
  def sign(agent_id, workspace_id)
      when is_binary(agent_id) and (is_binary(workspace_id) or is_nil(workspace_id)) do
    Phoenix.Token.sign(endpoint(), @salt, %{
      agent_id: agent_id,
      workspace_id: workspace_id
    })
  end

  @doc """
  Verify a bearer token. Returns `{:ok, %{agent_id:, workspace_id:}}` or
  `{:error, :invalid | :expired | :missing}`.
  """
  def verify(token) when is_binary(token) and token != "" do
    case Phoenix.Token.verify(endpoint(), @salt, token, max_age: @max_age_seconds) do
      {:ok, %{agent_id: agent_id} = claims} when is_binary(agent_id) ->
        {:ok, %{agent_id: agent_id, workspace_id: claims[:workspace_id]}}

      {:ok, _malformed} ->
        {:error, :invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def verify(_), do: {:error, :missing}

  defp endpoint, do: LoopyardWeb.Endpoint
end
