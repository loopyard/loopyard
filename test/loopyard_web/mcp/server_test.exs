defmodule LoopyardWeb.MCP.ServerTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Loopyard.MCP.Token

  @path "/mcp/acp"

  defp rpc(body, token) do
    conn =
      conn(:post, @path, "")
      |> put_req_header("content-type", "application/json")
      |> Map.put(:body_params, body)

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    LoopyardWeb.MCP.Server.call(conn, LoopyardWeb.MCP.Server.init([]))
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  setup do
    %{token: Token.sign("agent-xyz", "ws-xyz")}
  end

  test "rejects a request with no bearer token", %{} do
    conn = rpc(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}, nil)
    assert conn.status == 401
    assert ["Bearer"] = get_resp_header(conn, "www-authenticate")
  end

  test "rejects an invalid bearer token" do
    conn = rpc(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}, "garbage")
    assert conn.status == 401
  end

  test "initialize returns protocol + serverInfo", %{token: token} do
    conn = rpc(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}}, token)
    assert conn.status == 200
    body = decode(conn)
    assert body["id"] == 1
    assert body["result"]["serverInfo"]["name"] == "loopyard-container"
    assert body["result"]["capabilities"]["tools"]
    assert is_binary(body["result"]["protocolVersion"])
  end

  test "initialize echoes the client's requested protocol version", %{token: token} do
    body_in = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{"protocolVersion" => "2024-11-05"}
    }

    body = rpc(body_in, token) |> decode()
    assert body["result"]["protocolVersion"] == "2024-11-05"
  end

  test "tools/list returns the control-plane tools", %{token: token} do
    body = rpc(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}, token) |> decode()
    names = Enum.map(body["result"]["tools"], & &1["name"])
    assert "ports" in names
    assert "propose_fork" in names
    refute "exec" in names
  end

  test "notifications return 202 with no body", %{token: token} do
    conn = rpc(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, token)
    assert conn.status == 202
    assert conn.resp_body == ""
  end

  test "unknown method returns JSON-RPC method-not-found", %{token: token} do
    body = rpc(%{"jsonrpc" => "2.0", "id" => 9, "method" => "no/such"}, token) |> decode()
    assert body["error"]["code"] == -32601
    assert body["id"] == 9
  end

  test "tools/call with a missing name is invalid params", %{token: token} do
    body =
      rpc(
        %{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/call", "params" => %{}},
        token
      )
      |> decode()

    assert body["error"]["code"] == -32602
  end

  test "tools/call to an unknown tool is invalid params", %{token: token} do
    body =
      rpc(
        %{
          "jsonrpc" => "2.0",
          "id" => 4,
          "method" => "tools/call",
          "params" => %{"name" => "does_not_exist", "arguments" => %{}}
        },
        token
      )
      |> decode()

    assert body["error"]["code"] == -32602
    assert body["error"]["message"] =~ "unknown tool"
  end

  test "a batch of requests returns an array of responses", %{token: token} do
    batch = [
      %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"},
      %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
      %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}
    ]

    conn = rpc(batch, token)
    assert conn.status == 200
    responses = decode(conn)
    # The notification produces no response; the two requests do.
    assert length(responses) == 2
    assert Enum.map(responses, & &1["id"]) |> Enum.sort() == [1, 2]
  end
end
