defmodule Loopyard.MCP do
  @moduledoc """
  Entry points for the ACP MCP bridge — the seam that lets an in-container ACP
  harness reach Loopyard's control-plane tools over HTTP.

  Two things live here:

    * `acp_mcp_servers/2` — the `mcpServers` list Loopyard hands the ACP adapter
      in `session/new`. One HTTP server ("loopyard-container") pointed at this
      node's MCP plug, carrying a per-agent bearer token.
    * `base_url/0` — where the container reaches that plug. Config-overridable
      because "how a container reaches the host" is environment-specific.

  See `Loopyard.MCP.Token`, `Loopyard.MCP.ToolRouter`, and
  `LoopyardWeb.MCP.Server`.
  """

  alias Loopyard.MCP.{Token, ToolRouter}

  @path "/mcp/acp"

  @doc """
  Build the ACP `mcpServers` spec list for one agent. Mints a scoped bearer
  token and points the adapter at this node's MCP plug. Returns `[]` when the
  URL isn't configured/derivable, so a missing setting degrades to "no Loopyard
  tools" rather than a broken session.
  """
  def acp_mcp_servers(agent_id, workspace_id) when is_binary(agent_id) do
    case base_url() do
      nil ->
        []

      base ->
        token = Token.sign(agent_id, workspace_id)

        [
          %{
            "type" => "http",
            "name" => ToolRouter.server_name(),
            "url" => base <> @path,
            "headers" => [
              %{"name" => "Authorization", "value" => "Bearer " <> token}
            ]
          }
        ]
    end
  end

  @doc """
  Base URL a workspace container uses to reach the MCP bridge.

  Precedence:
    1. `config :loopyard, :acp_mcp_url` (or `LOOPYARD_MCP_URL`) — explicit override.
    2. `http://host.docker.internal:<port>` — the Docker-host alias every
       workspace container can resolve (provided by the Docker runtime), with
       the dedicated MCP listener's port (NOT the main web endpoint's).
  """
  def base_url do
    case configured_url() do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> "http://host.docker.internal:#{LoopyardWeb.MCP.Listener.port()}"
    end
  end

  defp configured_url do
    System.get_env("LOOPYARD_MCP_URL") || Application.get_env(:loopyard, :acp_mcp_url)
  end
end
