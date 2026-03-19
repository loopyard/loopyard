defmodule BoomLooper.Tools.SecretsTest do
  use ExUnit.Case

  alias BoomLooper.Tools.Secrets

  describe "module structure" do
    test "is a valid MCP server" do
      assert ClaudeCode.MCP.Server.sdk_server?(Secrets)
    end

    test "has correct server name and 2 tools" do
      info = Secrets.__tool_server__()
      assert info.name == "boom-looper-secrets"
      assert length(info.tools) == 2
    end

    test "tool names match expected" do
      tool_names = Secrets.__tool_server__().tools |> Enum.map(& &1.__tool_name__())
      assert "list_secrets" in tool_names
      assert "get_secret" in tool_names
    end
  end

  describe "do_list_secrets/0" do
    test "returns a list" do
      result = Secrets.do_list_secrets()
      assert is_list(result)
    end
  end

  describe "do_get_secret/1" do
    setup do
      BoomLooper.Secrets.put("test_tool_key", "Test Tool Secret", "tool_secret_val")

      on_exit(fn ->
        BoomLooper.Secrets.delete("test_tool_key")
      end)

      :ok
    end

    test "returns secret value for existing key" do
      assert {:ok, %{key: "test_tool_key", value: "tool_secret_val"}} =
               Secrets.do_get_secret("test_tool_key")
    end

    test "returns error for missing key" do
      assert {:error, msg} = Secrets.do_get_secret("nonexistent_tool_key")
      assert msg =~ "not found"
    end
  end
end
