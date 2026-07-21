defmodule Loopyard.MCP.ToolRouterTest do
  use ExUnit.Case, async: true

  alias Loopyard.MCP.ToolRouter

  # A minimal tool that echoes what it received, so we can assert on param
  # marshalling and identity binding without a live container.
  defmodule EchoTool do
    use Loopyard.Tool,
      name: "echo",
      description: "Echo params back",
      params: [
        agent_id: {:string, required: true},
        note: {:string, description: "free text"},
        opts: {:map, description: "nested object"}
      ]

    def execute(params, _assigns), do: {:ok, params}
  end

  defmodule OkTool do
    use Loopyard.Tool, name: "just_ok", description: "returns :ok", params: [agent_id: :string]
    def execute(_params, _assigns), do: :ok
  end

  defmodule DataTool do
    use Loopyard.Tool, name: "data", description: "returns a map", params: [agent_id: :string]
    def execute(_params, _assigns), do: {:ok, %{count: 3, items: ["a", "b"]}}
  end

  defmodule ErrTool do
    use Loopyard.Tool, name: "boom", description: "errors", params: [agent_id: :string]
    def execute(_params, _assigns), do: {:error, "kaboom"}
  end

  @modules [EchoTool, OkTool, DataTool, ErrTool]

  describe "list_tools/1" do
    test "returns bare-named specs with schema" do
      specs = ToolRouter.list_tools(@modules)
      names = Enum.map(specs, & &1["name"])
      assert "echo" in names
      assert "just_ok" in names

      echo = Enum.find(specs, &(&1["name"] == "echo"))
      assert echo["description"] == "Echo params back"
      assert echo["inputSchema"]["type"] == "object"
      assert "note" in Map.keys(echo["inputSchema"]["properties"])
    end
  end

  describe "call_tool/4 param marshalling" do
    test "atomizes top-level declared keys, leaves nested values string-keyed" do
      args = %{"note" => "hi", "opts" => %{"deep" => %{"k" => "v"}}}
      result = ToolRouter.call_tool("echo", args, "agent-1", @modules)

      assert %{"isError" => false, "content" => [%{"type" => "text", "text" => json}]} = result
      echoed = Jason.decode!(json)

      # top-level keys came back as the atom-keyed params the tool received,
      # re-encoded to JSON → string keys again; nested object preserved verbatim.
      assert echoed["note"] == "hi"
      assert echoed["opts"] == %{"deep" => %{"k" => "v"}}
    end

    test "forces agent_id from the token, ignoring a foreign one in args" do
      args = %{"agent_id" => "SOMEONE-ELSE", "note" => "x"}
      result = ToolRouter.call_tool("echo", args, "real-agent", @modules)

      %{"content" => [%{"text" => json}]} = result
      assert Jason.decode!(json)["agent_id"] == "real-agent"
    end
  end

  describe "call_tool/4 result mapping" do
    test ":ok → ok text" do
      assert %{"isError" => false, "content" => [%{"text" => "ok"}]} =
               ToolRouter.call_tool("just_ok", %{}, "a", @modules)
    end

    test "structured data → JSON text" do
      %{"isError" => false, "content" => [%{"text" => json}]} =
        ToolRouter.call_tool("data", %{}, "a", @modules)

      assert Jason.decode!(json) == %{"count" => 3, "items" => ["a", "b"]}
    end

    test "{:error, msg} → isError text" do
      assert %{"isError" => true, "content" => [%{"text" => "kaboom"}]} =
               ToolRouter.call_tool("boom", %{}, "a", @modules)
    end

    test "unknown tool → {:error, :unknown_tool}" do
      assert {:error, :unknown_tool} = ToolRouter.call_tool("nope", %{}, "a", @modules)
    end
  end

  describe "default control-plane surface" do
    test "exposes the headline control-plane tools and NOT the fs/exec ones" do
      names = ToolRouter.list_tools() |> Enum.map(& &1["name"])

      # Control-plane tools an in-container ACP agent can't do natively:
      for t <- ~w(ports propose_fork propose_integrate propose_delete_workspace ask_user
                  request_secret get_secret app_url docker_compose) do
        assert t in names, "expected #{t} in ACP MCP surface"
      end

      # Redundant with the container's native tools — must NOT be exposed:
      for t <- ~w(exec read_file write_file edit grep glob tree) do
        refute t in names, "#{t} should NOT be in the ACP MCP surface"
      end
    end
  end
end
