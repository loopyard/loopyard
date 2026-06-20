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

  require Logger

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
  Check if the CLI session is alive; auto-restart if not.

  Takes state, returns state with session alive (or error message
  appended if restart failed).
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

      case state.backend.start_session(start_opts(state)) do
        {:ok, new_session} ->
          Loopyard.EventLog.info("agent:#{state.name}", "CLI session restarted")

          ok_content =
            if is_binary(state.claude_session_id) do
              "Reconnected (resumed conversation #{String.slice(state.claude_session_id, 0..7)}…)."
            else
              "Reconnected."
            end

          ok_msg = %{role: :system, content: ok_content, timestamp: DateTime.utc_now()}
          {state, ok_msg} = append_message(track_os_pid(%{state | session: new_session}), ok_msg)

          Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
            agent_id: state.id,
            msg: ok_msg
          })

          state

        {:error, reason} ->
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

    case state.backend.start_session(start_opts(state)) do
      {:ok, new_session} ->
        content =
          if is_binary(state.claude_session_id) do
            "Session crashed — restarted automatically (attempt #{consecutive}, resumed conversation #{String.slice(state.claude_session_id, 0..7)}…)."
          else
            "Session crashed — restarted automatically (attempt #{consecutive})."
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

        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
        {:noreply, state}

      {:error, reason} ->
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
        state = %{state | status: :idle, active_tool: nil, errors: state.errors + 1}
        state = Map.put(state, :consecutive_crashes, consecutive)
        state = Map.delete(state, :retry_from_session)

        Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
          agent_id: id,
          msg: error_msg
        })

        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
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
end
