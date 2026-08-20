defmodule Loopyard.ChatAgent.Summary do
  @moduledoc """
  The agent's read-side projection: the map every reader (UI assigns, the
  ETS row, Attention, the operator's overview) sees. Pure `state -> map`;
  this module owns the field list so ChatAgent doesn't carry it inline.

  Messages are reversed here (the log stores newest-first for O(1)
  append) and card patches are reconciled at read time — see
  `Loopyard.ChatAgent.MessageLog.reconcile_card_patches/2`.
  """

  alias Loopyard.ChatAgent.MessageLog

  @doc "Build the public summary map from agent state."
  def build(state) do
    %{
      id: state.id,
      name: state.name,
      working_dir: state.working_dir,
      bind_mount: state.bind_mount,
      host_access: state.host_access,
      workspace_id: state.workspace_id,
      container: state.container,
      workstation_identity: state.workstation_identity,
      started_at: state.started_at,
      started_by: state.started_by,
      last_activity_at: state.last_activity_at,
      status: state.status,
      messages: MessageLog.reconcile_card_patches(state.id, Enum.reverse(state.messages)),
      tool_calls: state.tool_calls,
      errors: state.errors,
      service_name: state.service_name,
      model: state.model,
      # Which harness this agent runs on, so the picker can show the current
      # selection without reaching into session_opts from the view.
      harness: Loopyard.ChatAgent.HarnessControl.current(state),
      total_input_tokens: state.total_input_tokens,
      total_output_tokens: state.total_output_tokens,
      total_cache_read_tokens: state.total_cache_read_tokens,
      total_cost_usd: state.total_cost_usd,
      active_tool: state.active_tool,
      tool_calls_this_turn: Map.get(state, :tool_calls_this_turn, 0),
      turns: state.turns,
      claude_session_id: state.claude_session_id,
      rate_limit_status: state.rate_limit_status,
      rate_limit_resets_at_ms: state.rate_limit_resets_at_ms,
      rate_limit_type: state.rate_limit_type,
      rate_limit_utilization: state.rate_limit_utilization,
      auth_error: state.auth_error,
      # Preserved prompt of a turn that exhausted its transient-failure retries,
      # so the UI can offer one-tap Resend. nil when there's nothing to resend.
      failed_prompt: state.failed_prompt,
      prompt_hash: state.prompt_hash,
      context_utilization: state.context_utilization,
      pending_count: length(state.pending_sends),
      pending_messages: state.pending_sends
    }
  end
end
