defmodule Loopyard.Tools.SecretsTest do
  use ExUnit.Case

  alias Loopyard.Tools.Secrets

  describe "module structure" do
    test "is a valid MCP server" do
      assert ClaudeCode.MCP.Server.sdk_server?(Secrets)
    end

    test "has correct server name and 2 tools" do
      info = Secrets.__tool_server__()
      assert info.name == "loopyard-secrets"
      assert length(info.tools) == 2
    end

    test "tool names match expected" do
      tool_names = Secrets.__tool_server__().tools |> Enum.map(& &1.__tool_name__())
      assert "list_secrets" in tool_names
      assert "get_secret" in tool_names
    end
  end

  describe "do_list_secrets/2" do
    test "returns a list (unscoped agent sees all global secrets)" do
      result = Secrets.do_list_secrets(nil, nil)
      assert is_list(result)
    end
  end

  describe "do_get_secret/3" do
    setup do
      Loopyard.Secrets.put("test_tool_key", "Test Tool Secret", "tool_secret_val")
      Loopyard.Secrets.put("ws_scoped_key", "WS-only", "ws-value", ["ws-alpha"])

      on_exit(fn ->
        Loopyard.Secrets.delete("test_tool_key")
        Loopyard.Secrets.delete("ws_scoped_key")
      end)

      :ok
    end

    test "returns a global secret for any agent" do
      assert {:ok, %{key: "test_tool_key", value: "tool_secret_val"}} =
               Secrets.do_get_secret("test_tool_key", "any-ws", "any-proj")
    end

    test "returns error for missing key" do
      assert {:error, msg} = Secrets.do_get_secret("nonexistent_tool_key", nil, nil)
      assert msg =~ "not found"
    end

    test "scoped secret is visible to the matching workspace" do
      assert {:ok, %{value: "ws-value"}} =
               Secrets.do_get_secret("ws_scoped_key", "ws-alpha", nil)
    end

    test "scoped secret is NOT visible to a different workspace" do
      assert {:error, msg} =
               Secrets.do_get_secret("ws_scoped_key", "ws-beta", nil)

      assert msg =~ "not found"
    end
  end

  describe "resolve_scope/1" do
    test "returns nil/nil when assigns has no agent_id" do
      assert {nil, nil} = Secrets.resolve_scope(%{})
    end

    test "returns nil/nil for an unknown agent_id" do
      assert {nil, nil} = Secrets.resolve_scope(%{agent_id: "ghost-agent"})
    end
  end
end
