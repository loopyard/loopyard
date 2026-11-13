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

  `model` is set on a DELEGATION (kind `:agent`) once the backend reports the
  model the sub-agent ran on (ACP: the Agent tool's `toolResponse.resolvedModel`
  / `modelsUsed`); it lands on the `:tool` message as `:subagent_model`, which
  the sub-agent card names. nil = not reported (the card says nothing).
  """
  defstruct [:id, :name, :input, :kind, :parent_id, :model]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t(),
          input: map(),
          kind: Loopyard.Agent.ToolKind.t() | nil,
          parent_id: String.t() | nil,
          model: String.t() | nil
        }

  @doc """
  Stamp what this event knows beyond name/input onto its `:tool` message:
  `:parent_tool_id` for a harness-native sub-agent's call (so the transcript
  nests it under its `:agent` card) and `:subagent_model` for a delegation
  whose model was reported. Absent fields stay absent, so every other call's
  message shape is unchanged.
  """
  @spec stamp(map(), t()) :: map()
  def stamp(msg, %__MODULE__{parent_id: parent} = ev) when is_binary(parent),
    do: msg |> Map.put(:parent_tool_id, parent) |> stamp_model(ev)

  def stamp(msg, ev), do: stamp_model(msg, ev)

  @doc "Stamp a reported sub-agent model onto the `:tool` message (no-op when nil)."
  @spec stamp_model(map(), t()) :: map()
  def stamp_model(msg, %__MODULE__{model: model}) when is_binary(model) and model != "",
    do: Map.put(msg, :subagent_model, model)

  def stamp_model(msg, _event), do: msg
end
