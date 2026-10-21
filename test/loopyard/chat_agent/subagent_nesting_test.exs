defmodule Loopyard.ChatAgent.SubagentNestingTest do
  @moduledoc """
  A harness-native sub-agent's calls arrive as ordinary `%Event.ToolCall{}`s
  with `parent_id` set to the delegating call. StreamHandler must carry that
  onto the recorded `:tool` message (`parent_tool_id`) — and ONLY then — so
  the transcript can nest them; and the delegation itself records the
  `:agent` kind the backend stamped.
  """
  use Loopyard.AgentCase

  alias Loopyard.ChatAgent
  alias Loopyard.Agent.Event
  alias Loopyard.TestSupport.RecordingBackend

  @moduletag timeout: 10_000

  setup do
    RecordingBackend.reset()
    id = "subagent-nesting-#{:rand.uniform(100_000)}"

    {:ok, pid} =
      Loopyard.TestHelpers.start_agent(
        id: id,
        name: "Subagent Nesting",
        started_by: "test",
        backend: RecordingBackend
      )

    ChatAgent.subscribe(id)

    on_exit(fn ->
      try do
        ChatAgent.stop_agent(id)
      catch
        :exit, _ -> :ok
      end
    end)

    ref = make_ref()
    :sys.replace_state(pid, fn s -> %{s | stream_ref: ref, status: :thinking} end)
    %{id: id, pid: pid, ref: ref}
  end

  defp tool_msgs(pid) do
    :sys.get_state(pid).messages
    |> Enum.reverse()
    |> Enum.filter(&(&1.role in [:tool, :tool_result]))
  end

  test "a sub-agent's call records parent_tool_id; a top-level call records none",
       %{id: id, pid: pid, ref: ref} do
    send(
      pid,
      {:stream_event, id, ref,
       %Event.ToolCall{
         id: "t_agent",
         name: "Agent",
         kind: :agent,
         input: %{"description" => "Find callers", "subagent_type" => "Explore"}
       }}
    )

    send(
      pid,
      {:stream_event, id, ref,
       %Event.ToolCall{
         id: "t_child",
         name: "Bash",
         input: %{"command" => "pwd"},
         parent_id: "t_agent"
       }}
    )

    send(pid, {:stream_event, id, ref, %Event.ToolResult{id: "t_child", content: "/workspace"}})

    send(
      pid,
      {:stream_event, id, ref,
       %Event.ToolCall{id: "t_top", name: "Bash", input: %{"command" => "ls"}}}
    )

    _ = :sys.get_state(pid)

    assert [agent, child, child_result, top] = tool_msgs(pid)

    assert agent.tool_id == "t_agent"
    assert agent.tool_kind == :agent
    refute Map.has_key?(agent, :parent_tool_id)

    assert child.tool_id == "t_child"
    assert child.parent_tool_id == "t_agent"
    # The child's kind still classifies from its own name — nesting doesn't
    # change what the call IS.
    assert child.tool_kind == :command

    # Results pair by tool_id as ever; lineage lives on the call.
    assert child_result.role == :tool_result and child_result.tool_id == "t_child"

    refute Map.has_key?(top, :parent_tool_id)
  end

  test "a refinement of the parent call (arguments streaming in) keeps the nested child intact",
       %{id: id, pid: pid, ref: ref} do
    send(
      pid,
      {:stream_event, id, ref,
       %Event.ToolCall{id: "t_agent", name: "Agent", kind: :agent, input: %{"description" => "x"}}}
    )

    send(
      pid,
      {:stream_event, id, ref,
       %Event.ToolCall{
         id: "t_child",
         name: "Read",
         input: %{"file_path" => "/workspace/a"},
         parent_id: "t_agent"
       }}
    )

    # Late argument for the parent — same id → refine, not a second call.
    send(
      pid,
      {:stream_event, id, ref,
       %Event.ToolCall{
         id: "t_agent",
         name: "Agent",
         kind: :agent,
         input: %{"prompt" => "find it"}
       }}
    )

    _ = :sys.get_state(pid)

    assert [agent, child] = tool_msgs(pid)
    assert agent.input == %{"description" => "x", "prompt" => "find it"}
    assert child.parent_tool_id == "t_agent"
    assert :sys.get_state(pid).tool_calls == 2
  end
end
