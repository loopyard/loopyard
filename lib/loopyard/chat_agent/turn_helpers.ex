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

  # A turn is only genuinely in flight if its stream is live. A real
  # :thinking turn always carries a stream_ref (set with the status flip in
  # start_turn) backed by a live session. :thinking with NO stream_ref AND
  # NO live session is a ghost — the turn died without resetting to idle.
  #
  # DELIBERATELY NARROW (`stream_ref: nil`), because this runs on the HOT SEND
  # PATH. `live_session?` costs an ACP `Connection.ping` — a JSON-RPC round-trip
  # with a 2s timeout — so it must only run when a stream_ref is already absent
  # (rare). Widening it to every `:thinking` would ping on every send during a
  # turn, and a ping queued behind a streaming firehose can time out and report
  # a HEALTHY session as dead — killing the user's in-flight turn. The
  # stale-ref-over-dead-session wedge is caught by `stranded_turn?/2` instead,
  # which only runs off the hot path and checks the cheap time guard first.
  def ghost_thinking?(%{status: :thinking, stream_ref: nil} = state),
    do: not live_session?(state)

  def ghost_thinking?(_), do: false

  @doc """
  True when a turn is STRANDED: `:thinking`, silent past `grace_ms`, and backed
  by no live session — so it can never complete and nothing else will reap it
  (a stale `stream_ref` left by a failed recovery no longer matches the stall
  watchdog). For the periodic self-heal sweep ONLY — never the send path.

  Order matters: the cheap timestamp guard runs FIRST and short-circuits, so the
  expensive `live_session?` ping only happens on a turn that has already been
  silent for `grace_ms` — never against an actively-streaming connection, where
  a queued ping could time out and misreport a healthy session as dead.
  """
  def stranded_turn?(%{status: :thinking} = state, grace_ms) do
    silent_for?(state, grace_ms) and not live_session?(state)
  end

  def stranded_turn?(_, _), do: false

  defp silent_for?(%{last_activity_at: %DateTime{} = la}, grace_ms),
    do: DateTime.diff(DateTime.utc_now(), la, :millisecond) >= grace_ms

  # No activity timestamp at all → treat as silent (nothing to prove it's live).
  defp silent_for?(_, _), do: true

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

    deadline = Application.get_env(:loopyard, :interrupt_deadline_ms, @interrupt_deadline_ms)

    case Task.yield(task, deadline) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} -> true
      _ -> false
    end
  end
end
