defmodule Loopyard.ChatAgent.WorkstationControl do
  @moduledoc """
  Account switching for a ChatAgent — the sidebar's "run this agent as
  brad@rocketship" row. The workstation identity is the account whose
  credentials the harness signs in with, so this is the "who pays for this
  agent's tokens" control.

  Like `HarnessControl`, the switch can't be applied to the live session: a
  harness sources its credentials at launch and holds them until it exits. So
  `switch/2` re-stamps the agent (`workstation_identity` on state, the summary
  row, the ETF log, `session_opts` and the reload opts) and asks for a
  `:credentials` restart, which DROPS the native session id — the new account
  can't see the old account's session — and rebuilds the conversation from
  Loopyard's durable log (`ResumeMessage` seed + `recall_conversation`).
  The relaunch sources the new identity's env file in the work container
  (`Harness.Identity`); the token never crosses the command line.

  Restricted to WORKSPACE agents: a system agent's identity is where it
  lives (its workstation container, its `SystemGroup`, its agents log), not
  an account it can be moved between.

  A no-op switch (same identity) is deliberately NOT a restart.
  """

  alias Loopyard.ChatAgent.Persistence
  alias Loopyard.Events
  alias Loopyard.Workstation

  @ets_table :chat_agents

  @doc """
  The `{:set_workstation, …}` cast body. Runs IN the agent's process (it
  self-casts the restart) and returns the `{:noreply, state}` shape.
  """
  def handle_switch(state, workstation_id) do
    case switch(state, workstation_id) do
      {state, :restart} ->
        GenServer.cast(self(), {:restart_session, :credentials})
        {:noreply, state}

      {state, :noop} ->
        {:noreply, state}

      {state, {:error, reason}} ->
        Loopyard.EventLog.warning(
          "agent:#{state.name}",
          "Account switch to #{inspect(workstation_id)} refused: #{inspect(reason)}"
        )

        {:noreply, state}
    end
  end

  @doc """
  Move `state` onto `workstation_id`. Returns `{state, :restart | :noop |
  {:error, reason}}` — the caller casts the restart, so this stays a pure-ish
  state transition. Refuses an unknown identity and a system agent.
  """
  @spec switch(map(), String.t()) :: {map(), :restart | :noop | {:error, term()}}
  def switch(state, workstation_id) do
    cond do
      Loopyard.Agents.scope(state) != :workspace ->
        {state, {:error, :system_agent}}

      Map.get(state, :workstation_identity) == workstation_id ->
        {state, :noop}

      not Workstation.exists?(workstation_id) ->
        {state, {:error, :not_found}}

      true ->
        {do_switch(state, workstation_id), :restart}
    end
  end

  defp do_switch(state, workstation_id) do
    state =
      state
      |> Map.put(:workstation_identity, workstation_id)
      |> Map.put(
        :session_opts,
        Keyword.put(Map.get(state, :session_opts) || [], :workstation_identity, workstation_id)
      )
      # The reload-restart rebuilds session_opts from these; without the new
      # identity here a later "Restart agent" would hand the agent back.
      |> Map.put(
        :init_opts,
        Keyword.put(Map.get(state, :init_opts) || [], :workstation_identity, workstation_id)
      )
      # "Reconnecting…" in the harness-status block for the restart's duration;
      # sends queue behind it (`:backoff` is the queue-and-deliver status).
      |> Map.put(:status, :backoff)
      # The old account's plan limit no longer describes this agent.
      |> Loopyard.ChatAgent.PlanLimit.on_account_switch()

    :ets.insert(@ets_table, {state.id, Loopyard.ChatAgent.summary(state)})
    Persistence.persist_agent(state, &Loopyard.ChatAgent.summary/1)

    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: :backoff})

    Loopyard.EventLog.info(
      "agent:#{state.name}",
      "Account switched to #{workstation_id} — restarting, conversation carried over"
    )

    state
  end
end
