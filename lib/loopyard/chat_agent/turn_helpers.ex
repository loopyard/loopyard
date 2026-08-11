defmodule Loopyard.ChatAgent.TurnHelpers do
  @moduledoc """
  Small turn/session helpers for `Loopyard.ChatAgent`: ghost-turn
  detection/recovery and the deadline-bounded warm interrupt. State in,
  state out (or a plain boolean) — the GenServer callbacks that use them
  stay in ChatAgent.
  """

  # Warm-interrupt deadline. The SDK's interrupt only blocks when the CLI is
  # wedged (stdin pipe full); a healthy interrupt acks in microseconds. If the
  # warm interrupt doesn't land within this window the CLI is wedged, so we
  # preempt the SDK's own 5s self-crash with a hard restart (kill + resume).
  # Keep it well under that 5s so we always win the race.
  @interrupt_deadline_ms 1_500

  # A real :thinking turn is backed by a LIVE session. :thinking with NO live
  # session is a ghost — the turn died without resetting to idle and can never
  # complete (a dead session produces no stream events). This covers BOTH
  # shapes: a nil stream_ref, AND a STALE stream_ref left pointing at a session
  # that has since died (recovery swapped the stream but the replacement died,
  # so the old stall-watchdog ref no longer matches and nothing reaps it). The
  # earlier guard checked only `stream_ref: nil` and missed the stale-ref wedge,
  # which stranded an agent in :thinking with a dead session for minutes.
  def ghost_thinking?(%{status: :thinking} = state), do: not live_session?(state)

  def ghost_thinking?(_), do: false

  @doc """
  True when a ghost turn has been stranded past `grace_ms` (or carries no
  activity timestamp at all — then it's definitely stale). Guards the periodic
  self-heal sweep against acting during a sub-second legitimate session swap.
  """
  def ghost_stalled?(%{last_activity_at: %DateTime{} = la}, grace_ms),
    do: DateTime.diff(DateTime.utc_now(), la, :millisecond) >= grace_ms

  def ghost_stalled?(_, _), do: true

  defp live_session?(%{session: nil}), do: false

  defp live_session?(%{session: session, backend: backend}) do
    backend.session_alive?(session)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # Clear all transient turn state and return to idle — same fields the
  # interrupt/stream-done resets clear (agent-sanity: every reset-to-idle
  # path clears transient state). Used to recover a ghost :thinking before
  # re-sending, so the fresh turn starts clean.
  def reset_ghost_turn(state) do
    %{
      state
      | status: :idle,
        stream_ref: nil,
        active_tool: nil,
        in_flight_partial: "",
        tool_calls_this_turn: 0,
        tool_runaway_warned: false,
        last_tool_call: nil,
        context_warning_sent: false,
        turn_retry_count: 0,
        pending_turn_error: nil,
        current_turn_prompt: nil,
        current_turn_origin: :human
    }
  end

  # Run the backend's warm interrupt under @interrupt_deadline_ms. Returns true if
  # it acked cleanly, false if it errored or timed out (CLI wedged → caller hard-
  # restarts). cancel_turn is exit-safe (it catches the SDK's own exits), so the
  # linked Task can't take us down; a timeout just means "wedged".
  def warm_interrupt(%{session: nil}), do: true

  def warm_interrupt(%{session: session, backend: backend}) do
    task = Task.async(fn -> backend.cancel_turn(session) end)

    case Task.yield(task, @interrupt_deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} -> true
      _ -> false
    end
  end
end
