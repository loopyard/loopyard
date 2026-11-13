defmodule Loopyard.ChatAgent.PlanLimit do
  @moduledoc """
  An agent at its plan limit — what the ChatAgent does about it, as plain code
  (no model decision). Runs IN the agent's process; state in, state out.

  * **The limit is the account's.** Every refusal is recorded against
    `{workstation_identity, harness}` in `Loopyard.AccountLimits`, and a send
    to an agent whose account is known to be spent is HELD (`hold/2`) — parked
    and limited until the account's reset — instead of burning a turn to
    rediscover it.
  * **Failover, opt-in.** If the account's owner listed fallbacks
    (`Workstation.Failover`), the agent moves to the first one that holds a
    credential for its harness and is not itself limited — through the same
    `WorkstationControl.switch/2` + `:credentials` restart the Account picker
    uses, so the conversation is rebuilt from Loopyard's log. The interrupted
    turn is put back at the head of the queue exactly once (the same
    queue-and-deliver the restart path drains), and the chat gets one quiet
    line. Never onto an account nobody named: whose plan pays matters.
  * **Nowhere to go** → the agent stays limited as before, and ONE inbox item
    (`Notifications.Item.plan_limit/3`) says so with the one action; it
    settles when the limit clears.
  * **Going home.** After a failover the agent remembers where it came from
    and moves back once that account's window resets — only while idle with
    nothing queued, and only when `:account_failover_return` is on (default).

  Ping-pong can't happen on one refusal: a failover only runs while the agent
  is `:rate_limited` (the switch flips it to `:backoff`), and a limited account
  is never a target, so A→B→A needs A's limit to have actually lapsed.
  """

  alias Loopyard.{AccountLimits, Notifications, Workstation}
  alias Loopyard.ChatAgent.{HarnessControl, MessageLog, Persistence, Restart}
  alias Loopyard.ChatAgent.{SendGuards, StreamHandler, WorkstationControl}
  alias Loopyard.Events
  alias Loopyard.Harness.Catalog
  alias Loopyard.Notifications.Item
  alias Loopyard.Workstation.{Env, Failover}

  @ets_table :chat_agents

  # When the agent is busy at its scheduled return, look again this soon.
  @return_busy_retry_ms 60_000

  # ── reads ───────────────────────────────────────────────────────────────

  @doc "The account (identity) the agent bills."
  def identity(state), do: Map.get(state, :workstation_identity)

  @doc "The harness the agent runs."
  def harness(state), do: HarnessControl.current(state)

  @doc "Is the agent's account known to be at its plan limit right now?"
  def known_limited?(state), do: AccountLimits.limited?(identity(state), harness(state))

  @doc """
  The account this agent may fail over to right now, or nil: the first of its
  account's permitted fallbacks that holds a credential for its harness and is
  not itself limited. Workspace agents only — a system agent's identity is
  where it lives.
  """
  @spec target(map()) :: String.t() | nil
  def target(state) do
    from = identity(state)
    h = harness(state)

    if is_binary(from) and Loopyard.Agents.scope(state) == :workspace do
      from
      |> Failover.fallbacks()
      |> Enum.find(&(&1 != from and credentialed?(&1, h) and not AccountLimits.limited?(&1, h)))
    end
  rescue
    _ -> nil
  end

  defp until_phrase(ms),
    do: if(t = AccountLimits.clock(ms), do: "until #{t}", else: "until it resets")

  # ── the refusal ─────────────────────────────────────────────────────────

  @doc """
  A turn was refused for a plan limit. Records it against the account (every
  refusal, so a sibling learns the latest reset) and says what to do on the
  FIRST refusal of this outage: `:failover` (a permitted account can take the
  work — the caller sends `{:plan_limit_failover, id}`) or `:stay`.
  """
  @spec note_rejection(map(), Loopyard.Agent.Event.RateLimitStatus.t()) :: :failover | :stay
  def note_rejection(state, rl) do
    if is_binary(identity(state)) do
      AccountLimits.mark(identity(state), harness(state), rl.resets_at_ms, %{
        type: rl.rate_limit_type,
        agent_id: state.id
      })
    end

    if target(state), do: :failover, else: :stay
  end

  @doc """
  A send while the agent's account is known to be spent: behave exactly as a
  refused turn would — park the message, sit `:rate_limited` until the
  account's reset — without spending a turn to find out.
  """
  def hold(state, text) do
    row = AccountLimits.get(identity(state), harness(state)) || %{until_ms: nil, type: nil}

    state = %{
      state
      | status: :rate_limited,
        rate_limit_status: :rejected,
        rate_limit_resets_at_ms: row.until_ms,
        rate_limit_type: row.type
    }

    state = Map.put_new(state, :limit_origin, :held)

    Process.send_after(
      self(),
      {:rate_limit_retry, state.id},
      StreamHandler.compute_rate_limit_wait_ms(row.until_ms)
    )

    state = SendGuards.park_for_later(state, text)

    if target(state) do
      send(self(), {:plan_limit_failover, state.id})
      state
    else
      raise_stuck(state)
    end
  end

  # ── failover ────────────────────────────────────────────────────────────

  @doc """
  The `{:plan_limit_failover, id}` handler. Only while still `:rate_limited`
  (a second refusal, or a stale message after the switch, is a no-op), and
  re-checks the target — the world may have moved since the refusal.
  """
  def failover(%{status: :rate_limited} = state) do
    case target(state) do
      nil -> {:noreply, raise_stuck(state)}
      to -> move(state, to)
    end
  end

  def failover(state), do: {:noreply, state}

  defp move(state, to) do
    from = identity(state)
    h = harness(state)
    until = AccountLimits.limited_until(from, h) || state.rate_limit_resets_at_ms
    home = Map.get(state, :failover_origin) || from

    # The interrupted turn, put back once. A held send is already queued.
    redrive =
      if Map.get(state, :limit_origin) == :turn, do: Restart.pending_user_prompts(state), else: []

    state =
      state
      |> StreamHandler.finalize_partial_on_stream_interrupt(state.id, :error)
      # A refused turn is over: late events from its stream are stale, and a
      # plan limit is not a harness crash (the compaction breaker must not
      # route this restart into a summarize-and-resend of its own).
      |> Map.merge(%{stream_ref: nil, active_tool: nil, in_flight_partial: ""})
      |> Map.put(:midturn_crashes, 0)
      |> Map.update!(:pending_sends, &(redrive ++ &1))

    case WorkstationControl.switch(state, to) do
      {state, :restart} ->
        state = Map.put(state, :failover_origin, home)

        state =
          line(state, "Moved to #{to} — #{from} is at its plan limit #{until_phrase(until)}.")

        telemetry(state, :failover, from, to, h)
        schedule_return(state, until)
        GenServer.cast(self(), {:restart_session, :credentials})
        {:noreply, state}

      {state, _refused} ->
        {:noreply, raise_stuck(state)}
    end
  end

  # ── going home ──────────────────────────────────────────────────────────

  defp return_enabled?, do: Application.get_env(:loopyard, :account_failover_return, true)

  defp schedule_return(state, until) do
    if return_enabled?() do
      Process.send_after(
        self(),
        {:plan_limit_return, state.id},
        StreamHandler.compute_rate_limit_wait_ms(until)
      )
    end
  end

  @doc """
  The `{:plan_limit_return, id}` handler: back to the account the agent failed
  over from once its window has reset — idle and with nothing queued only, so
  a return never cuts into work.
  """
  def maybe_return(state) do
    home = Map.get(state, :failover_origin)
    h = harness(state)

    cond do
      is_nil(home) ->
        {:noreply, state}

      not return_enabled?() or home == identity(state) or not Workstation.exists?(home) or
          not credentialed?(home, h) ->
        {:noreply, Map.delete(state, :failover_origin)}

      until = AccountLimits.limited_until(home, h) ->
        schedule_return(state, until)
        {:noreply, state}

      state.status != :idle or state.pending_sends != [] ->
        Process.send_after(self(), {:plan_limit_return, state.id}, @return_busy_retry_ms)
        {:noreply, state}

      true ->
        from = identity(state)

        case WorkstationControl.switch(state, home) do
          {state, :restart} ->
            state = line(state, "Back on #{home} — its plan limit has reset.")
            telemetry(state, :return, from, home, h)
            GenServer.cast(self(), {:restart_session, :credentials})
            {:noreply, state}

          {state, _} ->
            {:noreply, Map.delete(state, :failover_origin)}
        end
    end
  end

  # ── clearing ────────────────────────────────────────────────────────────

  @doc """
  The `{:rate_limit_retry, id}` tick while `:rate_limited`. Before the reset:
  reschedule quietly (and fail over if someone has since permitted an account
  that can take the work). A sibling learned a LATER reset for the account:
  adopt it. Window cleared: forget the account's limit, settle the inbox item,
  go idle, and hand back whatever queued (`{:drain, list, state}`).
  """
  def retry(state) do
    now = System.system_time(:millisecond)
    own = state.rate_limit_resets_at_ms
    row = AccountLimits.get(identity(state), harness(state))

    cond do
      is_integer(own) and now < own ->
        wait(state, own)

      match?(%{known: true}, row) ->
        wait(%{state | rate_limit_resets_at_ms: row.until_ms}, row.until_ms)

      true ->
        AccountLimits.clear(identity(state), harness(state))
        state = cleared(%{state | status: :idle})
        :ets.insert(@ets_table, {state.id, Loopyard.ChatAgent.summary(state)})
        Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: :idle})

        case state.pending_sends do
          [] -> {:noreply, state}
          pending -> {:drain, pending, %{state | pending_sends: []}}
        end
    end
  end

  defp wait(state, until) do
    Process.send_after(
      self(),
      {:rate_limit_retry, state.id},
      StreamHandler.compute_rate_limit_wait_ms(until)
    )

    if target(state), do: send(self(), {:plan_limit_failover, state.id})
    {:noreply, state}
  end

  @doc "A turn on the account was allowed: the account isn't limited."
  def allowed(state) do
    AccountLimits.clear(identity(state), harness(state))
    settle_stuck(state)
    Map.delete(state, :limit_origin)
  end

  @doc """
  The agent moved accounts (a failover, a return, or a human's pick): the old
  account's limit no longer describes it. Called from `WorkstationControl`.
  """
  def on_account_switch(state) do
    state
    |> cleared()
    |> Map.delete(:failover_origin)
  end

  defp cleared(state) do
    settle_stuck(state)

    state
    |> Map.merge(%{
      rate_limit_status: :ok,
      rate_limit_resets_at_ms: nil,
      rate_limit_type: nil,
      rate_limit_utilization: nil
    })
    |> Map.delete(:limit_origin)
  end

  # ── the inbox item ──────────────────────────────────────────────────────

  @doc """
  Nowhere to go: ONE inbox item for this agent (the store ignores a raise of
  an item already open), WHY / CONSEQUENCE / ACTION.
  """
  def raise_stuck(state) do
    acct = identity(state) || Workstation.current()
    h = harness(state)
    until = AccountLimits.limited_until(acct, h) || state.rate_limit_resets_at_ms

    label =
      "#{state.name} is at #{acct}'s #{Catalog.label(h)} plan limit #{until_phrase(until)}, " <>
        "and no permitted account can take the work. It picks back up on its own then — " <>
        "or open #{acct} to sign in or permit another account."

    Notifications.raise_item(
      Item.plan_limit(state.id, label, %{account: acct, harness: h, until_ms: until})
    )

    state
  rescue
    _ -> state
  end

  defp settle_stuck(state), do: Notifications.settle("limit:" <> state.id, :cleared)

  # ── helpers ─────────────────────────────────────────────────────────────

  defp credentialed?(acct, h), do: Catalog.credentialed?(h, Env.all(acct))

  # One quiet system line, through the same append + persist + publish every
  # agent-produced message takes.
  defp line(state, text) do
    msg = %{role: :system, content: text, timestamp: DateTime.utc_now()}
    {state, msg} = MessageLog.append(state, msg)
    Persistence.persist_message(state, msg)

    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
      agent_id: state.id,
      msg: msg
    })

    state
  end

  defp telemetry(state, direction, from, to, h) do
    :telemetry.execute([:loopyard, :agent, :account_failover], %{count: 1}, %{
      agent_id: state.id,
      direction: direction,
      from: from,
      to: to,
      harness: h
    })

    Loopyard.EventLog.info(
      "agent:#{state.name}",
      "Account #{direction}: #{from} → #{to} (#{Catalog.label(h)} plan limit)"
    )
  end
end
