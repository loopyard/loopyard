defmodule Loopyard.ChatAgent.SessionManager do
  @moduledoc """
  Session lifecycle management for ChatAgent.

  Owns the logic for starting, stopping, restarting, and health-checking
  the Claude CLI subprocess that backs each agent. Extracted from
  ChatAgent to keep the GenServer callbacks thin — they pattern-match
  and delegate here.

  Every public function takes an agent state struct and returns an
  updated state struct (or `{:noreply, state}` for handle_info-shaped
  callers like `handle_retry/3`).
  """

  alias Loopyard.Events

  # --- Stop backend session ---

  # Stop a backend session with a 3s timeout. Uses async_nolink so a
  # crash in backend.stop/1 never propagates back as an EXIT signal
  # to the ChatAgent GenServer — an unsupervised Task.async would
  # link and kill us. See plans/agent-sanity.md "unsupervised
  # Task.async" audit finding.
  #
  # Returns :ok regardless of what happened to the task. The caller
  # is stopping the session anyway; whether backend.stop cleanly
  # completed, timed out, or crashed is academic — the Janitor-owned
  # :claude_cli resource will SIGKILL the OS pid on our DOWN.
  @backend_stop_timeout_ms 3_000

  @doc """
  Stop the backend CLI session gracefully (3s cap).

  Takes the full agent state, stops `state.session` via `state.backend`,
  and returns `:ok`. Safe to call when session or backend is nil.
  """
  def stop(%{session: nil}), do: :ok
  def stop(%{backend: nil}), do: :ok

  def stop(%{session: session, backend: backend}) do
    stop_backend(session, backend)
  end

  # Also exposed for callers that have explicit session/backend values
  # (e.g. terminate/2 where state.session was already nilled out).
  @doc false
  def stop_backend(nil, _backend), do: :ok
  def stop_backend(_session, nil), do: :ok

  def stop_backend(session, backend) do
    task =
      Task.Supervisor.async_nolink(Loopyard.TaskSupervisor, fn ->
        backend.stop(session)
      end)

    case Task.yield(task, @backend_stop_timeout_ms) do
      {:ok, _} -> :ok
      {:exit, _} -> :ok
      nil -> Task.shutdown(task, :brutal_kill)
    end

    :ok
  end

  # --- Build resume opts ---

  @doc """
  THE single source of harness start options for every (re)start path —
  `:restart_session`, crash recovery, retry backoff, `ensure_alive`, and
  compaction all call this. It takes the opts frozen at the agent's first
  boot (`state.session_opts`) and re-applies the parts that must be LIVE:

    * config-driven opts (`:thinking`) — so a config change reaches agents
      booted before it, not only freshly-created ones,
    * `:resume` from the captured session id — so a respawned harness
      continues the same conversation instead of booting amnesic (cleared
      when there's no id, e.g. a deliberate fresh/compacted session).

  **Add any new config-driven session option HERE**, not at a call site —
  that's what keeps "a new harness flag" a one-place change.
  """
  def start_opts(state) do
    opts =
      Keyword.put(
        state.session_opts,
        :thinking,
        Application.get_env(:loopyard, :agent_thinking, :adaptive)
      )

    case state.claude_session_id do
      sid when is_binary(sid) and sid != "" ->
        Keyword.put(opts, :resume, sid)

      _ ->
        Keyword.delete(opts, :resume)
    end
  end

  # --- Track CLI OS PID ---

  @doc """
  Track the Claude CLI subprocess OS pid under this ChatAgent via
  Loopyard.Resources. On our DOWN (brutal_kill, node crash,
  :shutdown-timeout), the Janitor SIGKILLs the OS pid — covering the
  paths where `terminate/2` never runs.

  Returns state with `tracked_cli_os_pid` updated.
  """
  def track_os_pid(state) do
    # Release stale tracking — previous session's OS pid is no longer
    # ours, and re-tracking by kind+id would fail under a new owner.
    if state.tracked_cli_os_pid do
      Loopyard.Resources.release(:claude_cli, state.tracked_cli_os_pid)
    end

    case state.session && state.backend && Loopyard.ChatAgent.OSProcess.pid_of(state.session) do
      os_pid when is_integer(os_pid) ->
        release_fn = fn -> Loopyard.ChatAgent.OSProcess.kill(os_pid) end

        case Loopyard.Resources.track(self(), :claude_cli, os_pid, release_fn) do
          :ok ->
            %{state | tracked_cli_os_pid: os_pid}

          {:error, :already_tracked} ->
            %{state | tracked_cli_os_pid: nil}
        end

      _ ->
        %{state | tracked_cli_os_pid: nil}
    end
  end

  # --- Ensure session alive ---

  @doc """
  Record an unexpected CLI death for the compact-instead-of-resume breaker
  (see `midturn_crashes` on the ChatAgent struct and
  `Loopyard.ChatAgent.compaction_breaker_tripped?/1`). Map.get/put: agents
  live through hot reloads holding pre-upgrade structs. Reset by a clean
  turn completion and by every fresh/compacted session.
  """
  def note_cli_death(state),
    do: Map.put(state, :midturn_crashes, Map.get(state, :midturn_crashes, 0) + 1)

  @doc """
  Check if the CLI session is alive; auto-restart if not.

  Takes state, returns state with session alive (or error message
  appended if restart failed).

  When the compaction breaker is tripped, a DEAD session is deliberately
  left dead: respawning here would resume the history that keeps
  OOM-killing the harness. The caller's dead-session check then casts
  `:restart_session`, whose breaker gate compacts instead.
  """
  def ensure_alive(state) do
    alive =
      try do
        state.backend.session_alive?(state.session)
      rescue
        _ -> false
      catch
        :exit, _ -> false
      end

    if alive do
      state
    else
      # Only a session that EXISTED and died counts as a crash — the idle
      # reaper stops the CLI intentionally and clears state.session, and
      # that must not trip the breaker.
      state = if state.session, do: note_cli_death(state), else: state

      if Loopyard.ChatAgent.compaction_breaker_tripped?(state) do
        state
      else
        ensure_alive_respawn(state)
      end
    end
  end

  defp ensure_alive_respawn(state) do
    Loopyard.EventLog.warning("agent:#{state.name}", "CLI session dead, auto-restarting")

      restart_msg = %{
        role: :system,
        content: "Session lost — reconnecting...",
        timestamp: DateTime.utc_now()
      }

      {state, restart_msg} = append_message(state, restart_msg)

      Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
        agent_id: state.id,
        msg: restart_msg
      })

      case start_session_safe(state) do
        {:ok, new_session, live_id} ->
          Loopyard.EventLog.info("agent:#{state.name}", "CLI session restarted")

          ok_content =
            if is_binary(live_id) do
              "Reconnected (resumed conversation #{String.slice(live_id, 0..7)}…)."
            else
              "Reconnected (fresh conversation)."
            end

          ok_msg = %{role: :system, content: ok_content, timestamp: DateTime.utc_now()}

          {state, ok_msg} =
            append_message(
              track_os_pid(%{state | session: new_session, claude_session_id: live_id}),
              ok_msg
            )

          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
            agent_id: state.id,
            msg: ok_msg
          })

          state

        {:error, reason, next_hint} ->
          state = %{state | claude_session_id: next_hint}
          Loopyard.EventLog.error(
            "agent:#{state.name}",
            "Failed to restart CLI: #{inspect(reason)}"
          )

          fail_msg = %{
            role: :error,
            content:
              "Failed to reconnect to the agent harness: #{inspect(reason)}. " <>
                "WHY: the harness session died, and trying to spawn a new one failed. " <>
                "CONSEQUENCE: your message was saved but won't be processed until the harness is back. " <>
                "ACTION: (1) check the harness is installed in the container and authenticated, " <>
                "(2) click Restart in the sidebar, " <>
                "(3) send your message again. Prior conversation context is preserved.",
            timestamp: DateTime.utc_now()
          }

          {state, fail_msg} = append_message(state, fail_msg)

          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
            agent_id: state.id,
            msg: fail_msg
          })

          state
      end
  end

  # --- Retry session after crash ---

  @doc """
  Handle the actual retry logic after a crash + backoff.

  Returns `{:noreply, state}` for direct use in handle_info clauses.
  `consecutive` is the crash count, `max_consecutive_crashes` is the
  module-attribute limit passed by the caller.
  """
  def handle_retry(state, consecutive, max_consecutive_crashes) do
    id = state.id

    case start_session_safe(state) do
      {:ok, new_session, live_id} ->
        content =
          if is_binary(live_id) do
            "Session crashed — restarted automatically (attempt #{consecutive}, resumed conversation #{String.slice(live_id, 0..7)}…)."
          else
            "Session crashed — restarted automatically (attempt #{consecutive}, fresh conversation)."
          end

        recovered_msg = %{
          role: :system,
          content: content,
          timestamp: DateTime.utc_now()
        }

        {state, recovered_msg} =
          append_message(
            track_os_pid(%{
              state
              | session: new_session,
                claude_session_id: live_id,
                status: :idle,
                active_tool: nil,
                errors: state.errors + 1
            }),
            recovered_msg
          )

        state = Map.put(state, :consecutive_crashes, consecutive)
        state = Map.delete(state, :retry_from_session)

        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
          agent_id: id,
          msg: recovered_msg
        })

        :ets.insert(:chat_agents, {id, Loopyard.ChatAgent.summary(state)})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
        schedule_pending_drain(state)
        {:noreply, state}

      {:error, reason, next_hint} ->
        error_msg = %{
          role: :error,
          content:
            "Session retry ##{consecutive} failed: #{inspect(reason)}. " <>
              "WHY: exponential backoff expired; the attempt to re-spawn the Claude CLI errored. " <>
              "CONSEQUENCE: the agent is idle but the CLI isn't running. Your prior messages are preserved. " <>
              "ACTION: send another message — this triggers ensure_session_alive which will " <>
              "retry the spawn. If it keeps failing, check `claude --version` + auth, or " <>
              "click Restart. After #{max_consecutive_crashes} consecutive failures the " <>
              "agent will auto-quarantine until you intervene.",
          timestamp: DateTime.utc_now()
        }

        {state, error_msg} = append_message(state, error_msg)

        state = %{
          state
          | claude_session_id: next_hint,
            status: :idle,
            active_tool: nil,
            errors: state.errors + 1
        }
        state = Map.put(state, :consecutive_crashes, consecutive)
        state = Map.delete(state, :retry_from_session)

        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
          agent_id: id,
          msg: error_msg
        })

        :ets.insert(:chat_agents, {id, Loopyard.ChatAgent.summary(state)})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
        schedule_pending_drain(state)
        {:noreply, state}
    end
  end

  # A retry lands the agent back at :idle — with or without a live CLI. If
  # messages were queued during the crash window (:backoff / :thinking), they
  # MUST NOT sit stranded: :idle means nothing else will ever drain them (the
  # normal drain fires on turn completion, and no turn is running). Reuse the
  # restart path's :drain_resumed_pending machinery — delayed because right
  # after session/load the harness subprocess can still be spinning up
  # ("ProcessTransport is not ready for writing"). On the failed-retry path
  # the drain's send goes through ensure_session_alive, which re-attempts the
  # spawn — the exact recovery the error copy tells the user to trigger by
  # hand, still bounded by max_consecutive_crashes.
  defp schedule_pending_drain(%{pending_sends: []}), do: :ok

  defp schedule_pending_drain(_state) do
    settle_ms = Application.get_env(:loopyard, :pending_drain_settle_ms, 4_000)
    Process.send_after(self(), :drain_resumed_pending, settle_ms)
    :ok
  end

  @doc """
  Is an `{:EXIT, pid, _}` from the process backing the CURRENT turn?

  We can only PROVE an EXIT is stale when we know the current turn's
  stream-task pid (set in `ChatAgent.start_turn`) and the dead pid is neither
  it nor the current session — the replaced-session case #41 guards against. If
  there's no tracked task pid, we can't prove staleness, so we react rather
  than swallow a real crash.
  """
  def relevant_exit?(pid, state) do
    if is_pid(state.stream_task_pid) do
      pid == state.stream_task_pid or pid == state.session
    else
      true
    end
  end

  @doc """
  Handle the current turn's streaming task/session dying abnormally: append a
  `:crashed` message after `max_consecutive_crashes`, otherwise transition to
  `:backoff` and schedule a `:retry_session`. Returns `{:noreply, state}`.

  The caller (ChatAgent's `{:EXIT}` handler) is expected to have already
  finalized any partial text — keeping this module free of a StreamHandler
  dependency.
  """
  def handle_thinking_exit(reason, state, max_consecutive_crashes) do
    Loopyard.EventLog.warning("agent:#{state.name}", "Streaming task died: #{inspect(reason)}")
    id = state.id
    consecutive = Map.get(state, :consecutive_crashes, 0) + 1

    if consecutive > max_consecutive_crashes do
      error_msg = %{
        role: :error,
        content:
          "Agent crashed #{consecutive} times in a row — giving up to protect the harness API from hot-loop retries. " <>
            "WHY: the streaming task kept dying within the exponential-backoff window. Most common cause: " <>
            "a repeatable bug in a tool the agent keeps calling. " <>
            "CONSEQUENCE: this agent is now :crashed and won't auto-retry. Prior conversation is preserved. " <>
            "ACTION: (1) check /system/quarantine + /system/events for the crash reason, " <>
            "(2) fix the underlying issue (if it's a tool, run `mix test` on it), " <>
            "(3) click Restart in the sidebar to resume the conversation.",
        timestamp: DateTime.utc_now()
      }

      {state, error_msg} = append_message(state, error_msg)
      state = %{state | status: :crashed, active_tool: nil, errors: state.errors + 1}
      state = Map.put(state, :consecutive_crashes, consecutive)

      Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
        agent_id: id,
        msg: error_msg
      })

      # ETS-first, THEN broadcast (matching the :backoff sibling below and every
      # happy-path transition). Skipping this left ETS at the pre-crash status,
      # so a viewer who mounts the page from the ETS fallback saw a stuck
      # "working" spinner on a crashed agent — never the red / Restart state.
      :ets.insert(:chat_agents, {id, Loopyard.ChatAgent.summary(state)})
      Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :crashed})
      {:noreply, state}
    else
      # Exponential backoff via Process.send_after (NOT a synchronous sleep).
      # Stash the dead session pid in retry_from_session so :retry_session can
      # detect a racing replacement (ensure_session_alive via a user send) and
      # skip, avoiding an orphaned CLI. Audit-2 HIGH #2 + LOW #7.
      base = Application.get_env(:loopyard, :crash_backoff_base_ms, 2_000)
      backoff_ms = Loopyard.Retry.backoff_ms(consecutive, {:exponential, base})

      Loopyard.EventLog.info(
        "agent:#{state.name}",
        "Backing off #{backoff_ms}ms before restart (crash ##{consecutive})"
      )

      Process.send_after(self(), {:retry_session, consecutive, state.session}, backoff_ms)
      state = %{state | status: :backoff, active_tool: nil}
      state = Map.put(state, :consecutive_crashes, consecutive)
      state = Map.put(state, :retry_from_session, state.session)
      :ets.insert(:chat_agents, {id, Loopyard.ChatAgent.summary(state)})
      Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :backoff})
      {:noreply, state}
    end
  end

  # --- Private helpers ---

  # Duplicated from ChatAgent — pure state transform for O(1) message
  # append. SessionManager needs this to attach system/error messages
  # during session lifecycle transitions.
  @max_messages 1000

  defp append_message(state, msg) do
    msg = Map.put_new_lazy(msg, :id, fn -> generate_msg_id() end)
    reversed = [msg | state.messages]

    reversed =
      if length(reversed) > @max_messages, do: Enum.take(reversed, @max_messages), else: reversed

    {%{state | messages: reversed}, msg}
  end

  defp generate_msg_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
  @doc """
  Start the harness session and apply the two resume-reliability rules, returning
  the session id Loopyard should track next:

    * `{:ok, session, live_id}` — RULE 1 (adopt the live id). Read the harness's
      ACTUAL current session id back. If a stale/oversized `resume:` id failed to
      load and the connection fell back to a fresh `session/new` internally,
      `live_id` is the NEW id — so Loopyard stops clinging to the dead one. This
      is what makes the fallback STICK instead of re-resuming the monster every
      restart.
    * `{:error, reason, next_hint}` — RULE 2 (one-strike resume). A resume hint
      that failed to start is poison. `next_hint` is `nil` when we WERE resuming
      (drop it so the retry is a guaranteed-fresh `session/new`), otherwise the
      unchanged hint.

  Guarded against EXITs (call timeouts, dead pids): a harness that fails to come
  up is an expected `{:error, ...}`, never an abnormal crash.

  DESIGN: harness sessions are ephemeral; Loopyard's durable inbox (ETS) owns
  history. Resume is a best-effort hint, never a dependency — `session/new`
  always works, so the agent stays usable no matter how badly a resume fails.
  """
  def start_session_safe(state) do
    resuming? = is_binary(state.claude_session_id) and state.claude_session_id != ""

    case state.backend.start_session(start_opts(state)) do
      {:ok, session} ->
        {:ok, session, safe_session_id(state.backend, session) || state.claude_session_id}

      {:error, reason} ->
        {:error, reason, drop_hint_on_resume(state, resuming?, reason)}
    end
  catch
    :exit, reason ->
      {:error, {:start_exit, reason},
       drop_hint_on_resume(state, is_binary(state.claude_session_id), reason)}
  end

  # Read the harness's live session id without ever letting a probe crash the
  # caller (a wedged connection's session_id/1 could time out).
  defp safe_session_id(backend, session) do
    backend.session_id(session)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp drop_hint_on_resume(_state, false, _reason), do: nil

  defp drop_hint_on_resume(state, true, reason) do
    Loopyard.EventLog.warning(
      "agent:#{state.name}",
      "Resume of #{String.slice(to_string(state.claude_session_id), 0, 8)}… failed " <>
        "(#{inspect(reason, limit: 4)}); dropping it — the next start is a fresh conversation."
    )

    nil
  end
end
