defmodule Loopyard.Tools.RecallAvailableTest do
  @moduledoc """
  Every agent that HAS a durable conversation must be able to read it.

  Harness-portable memory is the whole reason `recall_conversation` exists: the
  conversation lives in Loopyard's log, not the harness session, so after a
  restart / model switch / harness switch the agent's context is empty while
  Loopyard still holds every message.

  The operator had the log and not the tool. So once its session restarted it
  genuinely could not recall what the user had already told it — and, correctly,
  said so and asked them to repeat themselves. The memory was portable to
  everyone except the agent the user talks to most.

  The tool is AGENT-scoped (it reads the `:chat_agents` summary by agent_id and
  is bound to the caller's own id by the token), so there is no toolkit where
  "this agent keeps a transcript" is true and this tool doesn't belong.
  """
  use ExUnit.Case, async: true

  alias Loopyard.ChatAgent.ToolConfig
  alias Loopyard.Tools.Container.RecallConversation

  test "the workspace agent can recall its own history" do
    assert RecallConversation in Loopyard.Tools.Container.__tool_server__().tools
  end

  test "the OPERATOR can recall its own history" do
    assert RecallConversation in Loopyard.Tools.ControlPlane.__tool_server__().tools,
           "the operator keeps a durable transcript but had no tool to read it"
  end

  test "both ACP toolsets expose it over the bridge" do
    assert RecallConversation in ToolConfig.acp_control_plane_tools(),
           "workspace agents run in-container; recall has to cross the MCP bridge"

    assert RecallConversation in ToolConfig.acp_operator_tools(),
           "the operator runs in-container too — same bridge, same need"
  end
end
