defmodule BoomLooper.ToolAuthorizationTest do
  @moduledoc """
  Session-bound agent_id enforcement.

  The MCP session is spawned with `assigns = %{agent_id: <id>}`. Tools
  verify the `params.agent_id` the model sent matches the bound id,
  rejecting any attempt to act as a different agent. This makes
  copy-pasted agent IDs inert — they're just text to anyone but the
  session that owns them.
  """
  use ExUnit.Case, async: false

  alias BoomLooper.Tool
  alias BoomLooper.ChatAgent.ToolConfig
  alias BoomLooper.Tools.Container.Exec

  @my_id "my-session-id"
  @their_id "someone-elses-id"
  @workspace_id "ws-tool-auth-test"

  setup do
    # Seed a workspace lookup so the underlying tool wouldn't bail on
    # "no workspace" before we can see the authorization decision.
    :ets.insert(:chat_agents, {@my_id, %{id: @my_id, workspace_id: @workspace_id, messages: []}})

    :ets.insert(
      :chat_agents,
      {@their_id, %{id: @their_id, workspace_id: "ws-other", messages: []}}
    )

    on_exit(fn ->
      :ets.delete(:chat_agents, @my_id)
      :ets.delete(:chat_agents, @their_id)
    end)

    :ok
  end

  describe "authorize_agent/2" do
    test "passes when no bound id is set (e.g. direct tests)" do
      assert :ok = Tool.authorize_agent(%{agent_id: "anything"}, %{})
    end

    test "passes when params.agent_id matches assigns.agent_id" do
      assert :ok =
               Tool.authorize_agent(
                 %{agent_id: @my_id},
                 %{agent_id: @my_id}
               )
    end

    test "passes when params has no agent_id (tool doesn't need it)" do
      assert :ok = Tool.authorize_agent(%{command: "echo"}, %{agent_id: @my_id})
    end

    test "rejects with a clear message when the supplied id isn't the bound id" do
      assert {:error, msg} =
               Tool.authorize_agent(
                 %{agent_id: @their_id},
                 %{agent_id: @my_id}
               )

      assert msg =~ "agent_id mismatch"
      assert msg =~ @my_id
      assert msg =~ @their_id
      assert msg =~ "only operate on their own workspace"
    end

    test "works with string keys too (survives JSON decoding idiosyncrasies)" do
      assert {:error, _} =
               Tool.authorize_agent(
                 %{"agent_id" => @their_id},
                 %{"agent_id" => @my_id}
               )
    end
  end

  describe "tool execute/2 enforcement" do
    test "a container tool rejects a foreign agent_id even when that agent exists" do
      # @their_id is a real agent — this is the exact attack we're
      # preventing. The bound session is @my_id; @their_id leaked into
      # the model's context somehow (copy-paste, prompt injection, log)
      # and the model tried to use it.
      assert {:error, msg} =
               Exec.execute(
                 %{agent_id: @their_id, command: "echo pwn"},
                 %{agent_id: @my_id}
               )

      assert msg =~ "agent_id mismatch"
    end

    test "a container tool accepts the bound agent_id unchanged" do
      # Authorization passes; the call may fail further down because no
      # real container is running, but NOT for authorization reasons.
      case Exec.execute(
             %{agent_id: @my_id, command: "echo hi"},
             %{agent_id: @my_id}
           ) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          refute reason =~ "agent_id mismatch",
                 "authorization should have passed; got: #{inspect(reason)}"
      end
    end

    test "direct test calls with empty assigns still work (no binding)" do
      # This is the backwards-compat path: existing unit tests pass
      # %{} for assigns and expect the tool to behave normally.
      case Exec.execute(%{agent_id: @my_id, command: "echo hi"}, %{}) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          refute reason =~ "agent_id mismatch"
      end
    end
  end

  describe "every tool in the default toolkit enforces session binding" do
    # Goal: if a new tool gets added without `use BoomLooper.Tool` (or
    # without explicitly calling `authorize_agent/2` for tools built on
    # the SDK macro), this test breaks. That's what we want — a new
    # tool must not silently bypass the boundary.

    test "every tool module rejects a mismatched params.agent_id" do
      tools =
        BoomLooper.Tools.Container.__tool_server__().tools ++
          BoomLooper.Tools.Workspace.__tool_server__().tools

      for tool_mod <- tools do
        name = tool_mod.__tool_name__()

        # Build a params map with every required field from the schema
        # plus a DELIBERATELY WRONG agent_id. We don't care what each
        # tool does with `command`/`path`/etc. — authorization must run
        # first and reject regardless.
        params = minimal_params_for(tool_mod, agent_id: @their_id)

        result = tool_mod.execute(params, %{agent_id: @my_id})

        assert {:error, msg} = result
        assert is_binary(msg)

        assert msg =~ "agent_id mismatch",
               "tool #{name} failed to reject a mismatched agent_id. Got: #{inspect(result)}. " <>
                 "Every tool must be either built with `use BoomLooper.Tool` " <>
                 "(auto-wrapped) or explicitly call `BoomLooper.Tool.authorize_agent/2`."
      end
    end
  end

  # Build a minimal valid params map for a tool, overriding the given
  # fields. Fills every required schema field with a placeholder — the
  # authorization check fires before field validation, so placeholders
  # are fine.
  defp minimal_params_for(tool_mod, overrides) do
    schema = tool_mod.input_schema()
    required = schema["required"] || []

    base =
      for field <- required, into: %{} do
        {String.to_atom(field), placeholder_for(schema["properties"][field]["type"])}
      end

    Enum.reduce(overrides, base, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end

  defp placeholder_for("integer"), do: 1
  defp placeholder_for("number"), do: 1
  defp placeholder_for("boolean"), do: false
  defp placeholder_for("array"), do: []
  defp placeholder_for("object"), do: %{}
  defp placeholder_for(_), do: "x"

  describe "build_mcp_servers/2 — assigns wiring" do
    test "includes agent_id in each server's assigns when supplied" do
      servers = ToolConfig.build_mcp_servers(ToolConfig.default_tools(), @my_id)

      for {_name, config} <- servers do
        assert %{module: _, assigns: %{agent_id: bound}} = config
        assert bound == @my_id
      end
    end

    test "produces empty assigns when no agent_id is supplied" do
      servers = ToolConfig.build_mcp_servers(ToolConfig.default_tools())

      for {_name, config} <- servers do
        assert %{module: _, assigns: %{}} = config
      end
    end
  end
end
