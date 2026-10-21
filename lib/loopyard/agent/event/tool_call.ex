defmodule Loopyard.Agent.Event.ToolCall do
  @moduledoc """
  The assistant is invoking a tool.

  `kind` is the neutral, harness-agnostic classification the UI renders by
  (`t:Loopyard.Agent.ToolKind.t/0`). A backend MAY set it to render its own
  tool vocabulary correctly; when `nil`, consumers classify from `name` via
  `Loopyard.Agent.ToolKind.classify/1`. This is the seam that keeps the door
  open for our own harnesses — the UI never matches raw tool names itself.

  `parent_id` is set when the call was made by a harness-native SUB-AGENT: it
  is the id of the delegating call (the parent's `Task`/`Agent` tool call,
  kind `:agent`) so the transcript can nest the sub-agent's work under it.
  `nil` for the agent's own top-level calls. The backend stamps it from
  whatever its wire carries (ACP: `_meta.claudeCode.parentToolUseId`); a
  backend that reports no lineage leaves it nil and the calls render flat.
  """
  defstruct [:id, :name, :input, :kind, :parent_id]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t(),
          input: map(),
          kind: Loopyard.Agent.ToolKind.t() | nil,
          parent_id: String.t() | nil
        }
end
