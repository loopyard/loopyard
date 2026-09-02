defmodule Loopyard.ChatAgent.RestartController do
  @moduledoc """
  Move #10 Quarantine (plans/archive/coordination-hardening.md).

  Owns every respawn decision for ChatAgents under a single
  workspace. Stock `DynamicSupervisor` supervises the actual agents
  with `restart: :temporary` — OTP never auto-restarts anything.
  When a ChatAgent crashes, this controller gets the `:DOWN` and
  decides synchronously whether to respawn or quarantine.

  This is option (a) from the design interview: deterministic, no
  race between supervisor auto-restart and quarantine decision. The
  restart decision happens in one place, in one process, in one
  synchronous step. Crash #5 triggers quarantine BEFORE crash #6
  can ever happen.

  ## Threshold

  Default: 5 crashes within 60 seconds quarantines the agent.
  Configurable via Application env for tests:

      Application.put_env(:loopyard, :quarantine_threshold, {5, 60_000})

  The threshold matches `ChatAgent.@max_consecutive_crashes` so the
  existing backoff semantics and the quarantine trigger agree.

  ## Quarantine state

  Lives in the agent's ETS summary as a `:quarantined` boolean plus
  a `:quarantine_reason` field. Persists across server restarts via
  the agent log. A quarantined agent:

    * Is not auto-respawned by the controller
    * Is skipped by `ServiceManager`'s log-replay respawn
    * Shows as `:quarantined` in `agent_display_status/1`
    * Must be released manually via `release/1` or the UI

  ## Release

  Operators release a quarantined agent from `/system/quarantine`
  (one click per agent) or via `mix loopyard.rpc`:

      mix loopyard.rpc 'Loopyard.ChatAgent.RestartController.release("agent-id")'

  Release clears the flag and respawns the agent via the normal
  start_agent path.
  """

  use GenServer
  require Logger

  @default_threshold_count 5
  @default_threshold_window_ms 60_000

  # Telemetry event fired when an actor enters quarantine. Paired
  # with `[:loopyard, :quarantine, :released]` on release.
  @telemetry_triggered [:loopyard, :quarantine, :triggered]
  @telemetry_released [:loopyard, :quarantine, :released]

  # Crash history ETS table (see init/1). Declared up here so helper
  # functions defined BEFORE init/1 (e.g. purge_history_for/2) can
  # reference it. Module attributes are resolved at compile time in
  # lexical order — defining this in init/1 meant earlier private
  # fns saw @history_table as undefined.
  @history_table :restart_controller_history

  # ── Public API ──

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(key_from(opts)))
  end

  # The controller's KEY: a workspace id (WorkspaceGroup passes `workspace_id:`)
  # or a system scope `{:system, identity}` (SystemGroup passes `scope:`). The
  # key names the registry entry, the agent DynamicSupervisor, and the crash
  # history rows.
  defp key_from(opts), do: Keyword.get(opts, :scope) || Keyword.fetch!(opts, :workspace_id)

  @doc """
  The registered name of the agent DynamicSupervisor for a scope key (a
  workspace id or `{:system, identity}`). Both groups register theirs in
  `Loopyard.WorkspaceAgentRegistry`; the key space is any term.
  """
  def agent_sup_name(key), do: {:via, Registry, {Loopyard.WorkspaceAgentRegistry, key}}

  @doc """
  Start a ChatAgent under the scope `key` (a workspace id, or
  `{:system, identity}`). Refuses if the agent is already quarantined —
  someone must `release/1` first.

  Returns `{:ok, pid}` | `{:error, :quarantined}` |
  `{:error, :workspace_not_running}` | `{:error, reason}`.
  """
  def start_agent(key, agent_opts) do
    id = Keyword.fetch!(agent_opts, :id)

    case quarantined?(id) do
      true -> {:error, :quarantined}
      false -> do_start_agent(key, agent_opts)
    end
  end

  @doc """
  Release a quarantined agent. Idempotent.

  Clears the `:quarantined` flag + associated metadata from the
  agent's ETS summary AND purges any crash history for this agent
  so the next attempt starts with a clean 0-of-N counter. Does NOT
  respawn the agent — the operator (or the UI's Start button) has
  to call `ChatAgent.start_agent/1` next. The separation is
  deliberate: operators typically want to investigate the crash
  cause before re-launching.
  """
  def release(agent_id) do
    case :ets.lookup(:chat_agents, agent_id) do
      [{^agent_id, summary}] ->
        cleared = Map.drop(summary, [:quarantined, :quarantine_reason, :quarantine_crashed_at])
        :ets.insert(:chat_agents, {agent_id, cleared})

        purge_history_for(Loopyard.Agents.scope_key(summary), agent_id)

        :telemetry.execute(@telemetry_released, %{count: 1}, %{agent_id: agent_id})

        Loopyard.Events.ChatAgent.publish(%Loopyard.Events.ChatAgent.Released{id: agent_id})

        Loopyard.EventLog.info(
          "quarantine:#{agent_id}",
          "Released from quarantine"
        )

        :ok

      [] ->
        :ok
    end
  end

  # Audit-2 MEDIUM #5: serialize release-side ETS writes through the
  # controller so they can't interleave with the controller's own
  # read-modify-write in handle_agent_down. Without this hop, the
  # race sequence was:
  #
  #   1. controller reads history stamps (to filter + append the
  #      new crash stamp)
  #   2. operator calls release/1 → :ets.delete wipes the row
  #   3. controller writes [now | stamps] back → crash stamp
  #      resurrects the just-released history
  #
  # The GenServer call funnels the delete through the same process
  # that owns the handle_agent_down message, so step 2 lands in the
  # mailbox after the DOWN is processed. If no controller is
  # registered (tests without a full supervision tree, boot gap),
  # fall back to the direct ETS delete — that path is genuinely
  # race-free because nothing's running that would also touch the
  # table.
  defp purge_history_for(workspace_id, agent_id) do
    case Registry.lookup(Loopyard.ChatAgent.RestartControllerRegistry, workspace_id) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, {:purge_history, agent_id}, 5_000)
        catch
          :exit, _ ->
            # Controller died or timed out — fall back to the direct
            # delete so release still clears the history.
            :ets.delete(@history_table, history_key(workspace_id, agent_id))
            :ok
        end

      [] ->
        :ets.delete(@history_table, history_key(workspace_id, agent_id))
        :ok
    end
  end

  @doc """
  Check whether an agent is currently quarantined. Reads the ETS
  summary directly — zero controller hops.
  """
  def quarantined?(agent_id) do
    case :ets.lookup(:chat_agents, agent_id) do
      [{^agent_id, %{quarantined: true}}] -> true
      _ -> false
    end
  end

  @doc """
  List every quarantined agent across all workspaces, with reason
  and when it was quarantined. For `/system/quarantine`.
  """
  def list_quarantined do
    :ets.tab2list(:chat_agents)
    |> Enum.filter(fn {_, summary} -> Map.get(summary, :quarantined) == true end)
    |> Enum.map(fn {id, summary} ->
      %{
        id: id,
        name: Map.get(summary, :name, "unknown"),
        workspace_id: Map.get(summary, :workspace_id),
        reason: Map.get(summary, :quarantine_reason),
        crashed_at: Map.get(summary, :quarantine_crashed_at)
      }
    end)
  end

  @doc false
  # Used by WorkspaceGroup.start_agent/2 as the entry point. Public
  # so the supervisor can reach this GenServer without a naming hack.
  def registered_name(key), do: via(key)

  # ── GenServer ──

  @impl true
  def init(opts) do
    key = key_from(opts)
    Loopyard.StateKeeper.ensure_tables!()

    state = %{
      key: key,
      # Map: monitor_ref → {agent_id, agent_opts}. Lives only in
      # process state — when this controller restarts, monitors are
      # dead anyway and new ones get attached on the next
      # start_agent call.
      monitors: %{},
      # Map: agent_id → agent_opts. Same lifetime reasoning as
      # monitors: gets rebuilt on respawn.
      agent_opts: %{}
    }

    # Crash history lives in ETS (`:restart_controller_history`)
    # keyed by {workspace_id, agent_id}. WorkspaceGroup uses
    # `:one_for_all` supervision, so a sibling crash restarts THIS
    # controller — without ETS durability the in-memory crash
    # counters would reset and an agent that was 4-of-5 crashes
    # would get a fresh 0-of-5. That silently bypasses quarantine.
    # See audit HIGH #3.
    {:ok, state}
  end

  defp history_key(workspace_id, agent_id), do: {workspace_id, agent_id}

  defp read_history(workspace_id, agent_id) do
    case :ets.lookup(@history_table, history_key(workspace_id, agent_id)) do
      [{_, stamps}] when is_list(stamps) -> stamps
      _ -> []
    end
  end

  defp write_history(workspace_id, agent_id, stamps) do
    :ets.insert(@history_table, {history_key(workspace_id, agent_id), stamps})
  end

  defp clear_history(workspace_id, agent_id) do
    :ets.delete(@history_table, history_key(workspace_id, agent_id))
  end

  @impl true
  def handle_call({:purge_history, agent_id}, _from, state) do
    # Audit-2 MEDIUM #5: same process that owns handle_agent_down's
    # read-modify-write owns the delete, so they serialize.
    :ets.delete(@history_table, history_key(state.key, agent_id))
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:start_agent, agent_opts}, _from, state) do
    key = state.key
    id = Keyword.fetch!(agent_opts, :id)

    # A WORKSPACE controller injects its workspace_id into the agent's opts
    # so ChatAgent.init/1 stores it (without it, every container tool said
    # "Agent X has no workspace"). A system controller's agents have none —
    # their scope is the identity — so nothing is injected. Caller-supplied
    # workspace_id wins if explicitly provided.
    agent_opts =
      if is_binary(key), do: Keyword.put_new(agent_opts, :workspace_id, key), else: agent_opts

    # The actual GenServer start goes through the DynamicSupervisor
    # so OTP owns child spec, shutdown, and link management. We just
    # monitor the pid that comes back.
    sup_name = agent_sup_name(key)

    case DynamicSupervisor.start_child(sup_name, {Loopyard.ChatAgent, agent_opts}) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        state =
          state
          |> put_in([:monitors, ref], {id, agent_opts})
          |> put_in([:agent_opts, id], agent_opts)

        {:reply, {:ok, pid}, state}

      {:error, {:already_started, pid}} ->
        {:reply, {:ok, pid}, state}

      {:error, reason} = err ->
        Logger.warning("[RestartController] #{id} start failed: #{inspect(reason)}")

        # BOOT failures count toward quarantine too. An agent whose init fails
        # cleanly ({:stop, {:harness_start_failed, _}} → start_child {:error})
        # is never monitored, so it never accrued crash history — log-replay
        # re-attempted it on every workspace reconnect, FOREVER, with no
        # terminal state. Same ETS-backed history + threshold as monitored
        # crashes: repeated boot failures now land in /system/quarantine as a
        # visible "needs attention" instead of an invisible retry loop.
        state = record_boot_failure(state, id, reason)
        {:reply, err, state}
    end
  end

  defp record_boot_failure(state, agent_id, reason) do
    now = System.monotonic_time(:millisecond)
    {count, window_ms} = threshold()

    history =
      read_history(state.key, agent_id)
      |> Enum.filter(&(now - &1 <= window_ms))

    history = [now | history]
    write_history(state.key, agent_id, history)

    if length(history) >= count do
      {:noreply, state} = quarantine(state, agent_id, {:boot_failed, reason})
      state
    else
      state
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        # Not one of ours — probably leftover from a previous start
        {:noreply, state}

      {{agent_id, agent_opts}, monitors} ->
        state = %{state | monitors: monitors}
        handle_agent_down(state, agent_id, agent_opts, reason)
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning(
      "[RestartController] #{inspect(state.key)} unhandled: #{inspect(msg, limit: 200)}"
    )

    :telemetry.execute(
      [:loopyard, :actor, :unknown_message],
      %{count: 1},
      %{actor: __MODULE__, scope: state.key, msg: inspect(msg, limit: 200)}
    )

    {:noreply, state}
  end

  # ── Core: respawn or quarantine ──

  # Normal shutdown (stop/remove/destroy) — no respawn, no crash
  # counted. Clean up tracking state + persisted history.
  defp handle_agent_down(state, agent_id, _opts, :normal) do
    state = update_in(state.agent_opts, &Map.delete(&1, agent_id))
    clear_history(state.key, agent_id)
    {:noreply, state}
  end

  defp handle_agent_down(state, agent_id, _opts, :shutdown) do
    # Supervisor-initiated shutdown (e.g. workspace tearing down).
    # Treat same as :normal.
    state = update_in(state.agent_opts, &Map.delete(&1, agent_id))
    clear_history(state.key, agent_id)
    {:noreply, state}
  end

  defp handle_agent_down(state, agent_id, _opts, {:shutdown, _}) do
    state = update_in(state.agent_opts, &Map.delete(&1, agent_id))
    clear_history(state.key, agent_id)
    {:noreply, state}
  end

  # Abnormal exit — count the crash, decide whether to respawn.
  # Crash history is ETS-backed (audit HIGH #3) so WorkspaceGroup's
  # :one_for_all restart of this controller can't reset the counter.
  defp handle_agent_down(state, agent_id, agent_opts, reason) do
    now = System.monotonic_time(:millisecond)
    {count, window_ms} = threshold()

    history =
      read_history(state.key, agent_id)
      |> Enum.filter(&(now - &1 <= window_ms))

    history = [now | history]
    write_history(state.key, agent_id, history)

    Logger.warning(
      "[RestartController] #{agent_id} crashed (#{length(history)}/#{count} in window): " <>
        inspect(reason, limit: 50)
    )

    if length(history) >= count do
      quarantine(state, agent_id, reason)
    else
      respawn(state, agent_id, agent_opts)
    end
  end

  defp quarantine(state, agent_id, reason) do
    now = DateTime.utc_now()

    # Mark the agent quarantined in ETS so (1) the UI renders it as
    # quarantined, (2) `quarantined?/1` is a pure ETS read, (3) the
    # summary persists via the normal agent log path.
    case :ets.lookup(:chat_agents, agent_id) do
      [{^agent_id, summary}] ->
        updated =
          Map.merge(summary, %{
            status: :crashed,
            quarantined: true,
            quarantine_reason: inspect(reason, limit: 100),
            quarantine_crashed_at: now
          })

        :ets.insert(:chat_agents, {agent_id, updated})

        Loopyard.Events.ChatAgent.publish(%Loopyard.Events.ChatAgent.Quarantined{
          id: agent_id,
          summary: updated
        })

      [] ->
        :ok
    end

    :telemetry.execute(@telemetry_triggered, %{crash_count: elem(threshold(), 0)}, %{
      agent_id: agent_id,
      reason: inspect(reason, limit: 100)
    })

    Loopyard.EventLog.error(
      "quarantine:#{agent_id}",
      "Quarantined after #{elem(threshold(), 0)} crashes in #{elem(threshold(), 1)}ms: " <>
        inspect(reason, limit: 100)
    )

    # Clear tracking — if operator releases, we start fresh. History
    # is in ETS; tracking is in-process.
    clear_history(state.key, agent_id)
    state = update_in(state.agent_opts, &Map.delete(&1, agent_id))
    {:noreply, state}
  end

  defp respawn(state, agent_id, agent_opts) do
    # Respawn with the same opts. The ChatAgent GenServer handles
    # resume-from-ETS via `resume: true` already; we pass opts
    # verbatim so whatever the original caller set carries through.
    sup_name = agent_sup_name(state.key)

    # Add resume: true so the respawned agent picks up existing state.
    opts = Keyword.put(agent_opts, :resume, true)

    case DynamicSupervisor.start_child(sup_name, {Loopyard.ChatAgent, opts}) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        state =
          state
          |> put_in([:monitors, ref], {agent_id, opts})
          |> put_in([:agent_opts, agent_id], opts)

        {:noreply, state}

      {:error, reason} ->
        # Couldn't respawn. Don't loop forever trying — treat as
        # quarantine so the operator sees it.
        Logger.error(
          "[RestartController] #{agent_id} respawn failed: #{inspect(reason)}. Quarantining."
        )

        quarantine(state, agent_id, {:respawn_failed, reason})
    end
  end

  # ── Internals ──

  defp do_start_agent(key, agent_opts) do
    case Registry.lookup(Loopyard.ChatAgent.RestartControllerRegistry, key) do
      [{pid, _}] ->
        # ChatAgent.init starts the Claude CLI session synchronously, so this call
        # blocks on the CLI coming up. When the workspace supervisor also has to be
        # rebuilt first (cold workspace / after a crash), 10s was too tight — the
        # agent booted fine a few seconds later but the saga had already reported
        # failure. 30s covers rebuild + CLI start. (Async init is the real fix; later.)
        # 150s (was 30s): a RESUMED agent's init replays its whole harness
        # session (ACP session/load budget: 120s) — this outer call must
        # exceed the inner budget or it times out first, killing the caller
        # while the boot actually succeeds underneath (the crash-loop shape).
        GenServer.call(pid, {:start_agent, agent_opts}, 150_000)

      [] ->
        {:error, :workspace_not_running}
    end
  end

  defp threshold do
    Application.get_env(
      :loopyard,
      :quarantine_threshold,
      {@default_threshold_count, @default_threshold_window_ms}
    )
  end

  defp via(key) do
    {:via, Registry, {Loopyard.ChatAgent.RestartControllerRegistry, key}}
  end
end
