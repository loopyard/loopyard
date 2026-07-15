defmodule LoopyardWeb.MCP.Server do
  @moduledoc """
  MCP-over-HTTP bridge for in-container ACP harnesses (the "loopyard-container"
  MCP server an ACP agent connects to). Speaks the MCP **Streamable HTTP**
  transport as a stateless JSON-RPC endpoint: the container POSTs a JSON-RPC
  request, we answer with a single `application/json` response — no SSE stream,
  no session id (each request carries its own bearer identity).

  Every request MUST carry `Authorization: Bearer <token>`; the token
  (`Loopyard.MCP.Token`) binds the whole session to one agent + workspace, and
  the tool layer (`Loopyard.MCP.ToolRouter` → `Loopyard.Tool.authorize_agent/2`)
  runs the call as that agent. A caller with no/invalid token gets 401 — this is
  the network edge of the workspace-agent sandbox boundary (docs/SECURITY.md).

  Methods handled: `initialize`, `notifications/initialized` (+ any other
  notification, ack-only), `ping`, `tools/list`, `tools/call`.
  """
  @behaviour Plug

  import Plug.Conn

  alias Loopyard.MCP.{Token, ToolRouter}

  # Fallback when the client doesn't state one; otherwise we echo theirs.
  @default_protocol "2025-06-18"
  @server_version Mix.Project.config()[:version] || "0.0.0"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST"} = conn, _opts) do
    case authenticate(conn) do
      {:ok, identity} -> dispatch(conn, conn.body_params, identity)
      {:error, reason} -> unauthorized(conn, reason)
    end
  end

  # Streamable HTTP allows a client-opened GET SSE stream for server→client
  # messages. We're stateless request/response, so we don't offer one.
  def call(%Plug.Conn{method: method} = conn, _opts) when method in ["GET", "DELETE"] do
    send_resp(conn, 405, "")
  end

  def call(conn, _opts), do: send_resp(conn, 405, "")

  # --- auth ---

  defp authenticate(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- String.trim(header) do
      Token.verify(token)
    else
      _ -> {:error, :missing}
    end
  end

  defp unauthorized(conn, reason) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> json(401, %{
      "error" => %{"code" => -32001, "message" => "unauthorized (#{reason})"},
      "jsonrpc" => "2.0",
      "id" => nil
    })
  end

  # --- JSON-RPC dispatch ---

  # Batch: an array of requests → array of (non-notification) responses.
  defp dispatch(conn, requests, identity) when is_list(requests) do
    responses =
      requests
      |> Enum.map(&handle_rpc(&1, identity))
      |> Enum.reject(&is_nil/1)

    if responses == [], do: send_resp(conn, 202, ""), else: json(conn, 200, responses)
  end

  defp dispatch(conn, request, identity) when is_map(request) do
    case handle_rpc(request, identity) do
      # A notification (no id) → nothing to return.
      nil -> send_resp(conn, 202, "")
      response -> json(conn, 200, response)
    end
  end

  defp dispatch(conn, _other, _identity) do
    json(conn, 200, error(nil, -32600, "invalid request"))
  end

  # A JSON-RPC message with no "id" is a notification — ack, return nothing.
  defp handle_rpc(%{"method" => method} = msg, identity) do
    id = msg["id"]
    params = msg["params"] || %{}
    result = handle_method(method, params, identity)

    cond do
      is_nil(id) -> nil
      match?({:error, _, _}, result) -> apply_error(id, result)
      true -> ok(id, result)
    end
  end

  defp handle_rpc(_malformed, _identity), do: nil

  defp apply_error(id, {:error, code, message}), do: error(id, code, message)

  # --- methods ---

  defp handle_method("initialize", params, _identity) do
    %{
      "protocolVersion" => params["protocolVersion"] || @default_protocol,
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "serverInfo" => %{"name" => ToolRouter.server_name(), "version" => @server_version}
    }
  end

  defp handle_method("ping", _params, _identity), do: %{}

  defp handle_method("tools/list", _params, _identity) do
    %{"tools" => ToolRouter.list_tools()}
  end

  defp handle_method("tools/call", params, %{agent_id: agent_id}) do
    name = params["name"]
    args = params["arguments"] || %{}

    cond do
      not is_binary(name) ->
        {:error, -32602, "missing tool name"}

      not is_map(args) ->
        {:error, -32602, "arguments must be an object"}

      true ->
        case ToolRouter.call_tool(name, args, agent_id) do
          {:error, :unknown_tool} -> {:error, -32602, "unknown tool: #{name}"}
          result -> result
        end
    end
  end

  # Notifications (initialized, cancelled, …) and anything else with no handler:
  # for a notification the caller drops the result; for a request it's method-not-found.
  defp handle_method("notifications/" <> _rest, _params, _identity), do: %{}
  defp handle_method(method, _params, _identity), do: {:error, -32601, "method not found: #{method}"}

  # --- JSON-RPC envelopes ---

  defp ok(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
