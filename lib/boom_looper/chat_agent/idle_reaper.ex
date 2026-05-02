defmodule BoomLooper.ChatAgent.IdleReaper do
  @moduledoc """
  Auto-stops CLI subprocesses for agents that have been idle too long.

  Extracted from ChatAgent (agent-sanity #20). Long-idle agents hold a
  Claude CLI subprocess (~200MB RSS) indefinitely. The reaper checks on
  a timer tick and stops the CLI when the agent has been idle past the
  threshold AND has a captured `claude_session_id` so the conversation
  can be resumed losslessly.

  Configuration (app env, overridable per-test):
    - `:agent_idle_reap_hours` (default 4) — idle threshold before reap
    - `:agent_idle_check_interval_ms` (default 600_000 = 10 min) — tick interval
  """

  @default_agent_idle_reap_hours 4
  @default_agent_idle_check_interval_ms 600_000

  @doc """
  Arms a single `:idle_check` timer. Cancels any existing timer first
  so repeated scheduling (e.g. after every activity) doesn't stack.

  Returns `state` with the new timer ref in `:idle_check_timer`.
  """
  def schedule(state) do
    if ref = state.idle_check_timer, do: Process.cancel_timer(ref)
    interval = Application.get_env(:boom_looper, :agent_idle_check_interval_ms, @default_agent_idle_check_interval_ms)
    timer = Process.send_after(self(), :idle_check, interval)
    %{state | idle_check_timer: timer}
  end

  @doc """
  Checks whether the agent should be reaped based on idle time.

  The critical invariant: we only reap when we have a captured
  `claude_session_id`. Without it, `ensure_session_alive` can't
  re-create the SAME conversation — it would spawn a fresh amnesic
  CLI. Better to hold the RAM than silently drop context.
  """
  def eligible?(state) do
    state.status == :idle and
      is_pid(state.session) and
      Process.alive?(state.session) and
      is_binary(state.claude_session_id) and
      state.claude_session_id != "" and
      state.last_activity_at != nil and
      DateTime.diff(DateTime.utc_now(), state.last_activity_at, :second) >= reap_threshold_seconds()
  end

  @doc """
  How many seconds of idleness before the CLI gets reaped.
  """
  def reap_threshold_seconds do
    hours = Application.get_env(:boom_looper, :agent_idle_reap_hours, @default_agent_idle_reap_hours)
    hours * 3600
  end
end
