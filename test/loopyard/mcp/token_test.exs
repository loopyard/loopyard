defmodule Loopyard.MCP.TokenTest do
  use ExUnit.Case, async: true

  alias Loopyard.MCP.Token

  test "signs and verifies a scoped token round-trip" do
    token = Token.sign("agent-abc", "ws-123")
    assert is_binary(token)
    assert {:ok, %{agent_id: "agent-abc", workspace_id: "ws-123"}} = Token.verify(token)
  end

  test "carries a nil workspace_id" do
    token = Token.sign("agent-abc", nil)
    assert {:ok, %{agent_id: "agent-abc", workspace_id: nil}} = Token.verify(token)
  end

  test "rejects a garbage token" do
    assert {:error, :invalid} = Token.verify("not-a-real-token")
  end

  test "rejects a tampered token" do
    token = Token.sign("agent-abc", "ws-123")
    tampered = token <> "x"
    assert {:error, reason} = Token.verify(tampered)
    assert reason in [:invalid, :expired]
  end

  test "rejects missing/empty token" do
    assert {:error, :missing} = Token.verify(nil)
    assert {:error, :missing} = Token.verify("")
  end

  test "a token for one agent verifies to exactly that agent (no cross-scope)" do
    a = Token.sign("agent-a", "ws-a")
    b = Token.sign("agent-b", "ws-b")

    assert {:ok, %{agent_id: "agent-a"}} = Token.verify(a)
    assert {:ok, %{agent_id: "agent-b"}} = Token.verify(b)
    refute a == b
  end
end
