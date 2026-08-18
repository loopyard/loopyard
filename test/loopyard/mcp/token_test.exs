defmodule Loopyard.MCP.TokenTest do
  use ExUnit.Case, async: false

  alias Loopyard.MCP.Token

  setup do
    Loopyard.StateKeeper.ensure_tables!()
    :ets.delete_all_objects(:mcp_token_epochs)
    :ok
  end

  describe "forgery resistance (#75)" do
    test "a token signed with the endpoint's secret_key_base is REJECTED" do
      # The committed dev secret_key_base must not be a valid signing key for
      # MCP tokens — that was the forge-from-the-public-repo hole.
      forged =
        Phoenix.Token.sign(LoopyardWeb.Endpoint, "acp mcp bearer v1", %{
          agent_id: "forged",
          workspace_id: nil,
          scope: :operator
        })

      assert {:error, _} = Token.verify(forged)
    end

    test "a token signed with the literal committed dev string is REJECTED" do
      committed =
        "dev_secret_key_base_that_is_at_least_64_bytes_long_for_hive_application_dev_mode"

      forged =
        Phoenix.Token.sign(committed, "acp mcp bearer v1", %{
          agent_id: "forged",
          workspace_id: nil,
          scope: :operator
        })

      assert {:error, _} = Token.verify(forged)
    end

    test "a token minted by Token.sign/3 verifies and round-trips its claims" do
      token = Token.sign("agent-a", "ws-a", :workspace)
      assert {:ok, claims} = Token.verify(token)
      assert claims.agent_id == "agent-a"
      assert claims.workspace_id == "ws-a"
      assert claims.scope == :workspace
    end
  end

  describe "revocation (#81)" do
    test "revoking an agent invalidates its outstanding tokens" do
      token = Token.sign("agent-b", "ws-b", :workspace)
      assert {:ok, _} = Token.verify(token)

      Token.revoke("agent-b")

      assert {:error, :invalid} = Token.verify(token)
    end

    test "revoking one agent does not affect another" do
      a = Token.sign("agent-c", "ws-c", :workspace)
      b = Token.sign("agent-d", "ws-d", :workspace)

      Token.revoke("agent-c")

      assert {:error, :invalid} = Token.verify(a)
      assert {:ok, _} = Token.verify(b)
    end

    test "a freshly minted token after revocation is valid again" do
      Token.revoke("agent-e")
      token = Token.sign("agent-e", "ws-e", :workspace)
      assert {:ok, _} = Token.verify(token)
    end
  end
end
