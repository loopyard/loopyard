defmodule Loopyard.ChatAgent.SubagentControl do
  @moduledoc """
  The sidebar's "Sub-agents" row: which model a harness's OWN sub-agents
  (Claude Code's `Task`/`Agent` delegations) run on — the cost lever for a
  capable main model directing cheaper workers. nil = "Same as the agent",
  i.e. nothing set and the harness behaves as it always did.

  The setting lives in `session_opts[:subagent_model]` (the summary row and the
  ETF `{:agent, …}` record read it from there; `Initializer.rebuild_session_opts/1`
  carries it through a `:reload`). HOW it reaches the harness is a per-harness
  fact in `Harness.Catalog` (`subagent_model_env/2`), applied at launch by
  `Harness.ACP.docker_exec_cmd/3` — so a change takes effect only on a relaunch.

  **The conversation is kept.** The relaunch is a `:settings` restart: same
  harness, same account, so the native session id is RESUMED (unlike a harness
  or account switch, which must drop it). It is silent — EventLog only; the
  harness-status block shows "Reconnecting…" meanwhile.

  **A busy agent is never killed for this.** While a turn runs, the new value
  is stored and shown at once, and the relaunch waits for the turn to end
  (re-checked every 2 s by a self-cast).

  A no-op change (same value) is deliberately NOT a restart.
  """

  alias Loopyard.ChatAgent.Persistence
  alias Loopyard.Events
  alias Loopyard.Harness.Catalog

  @ets_table :chat_agents
  @retry_ms 2_000

  @doc """
  The `{:set_subagent_model, …}` cast body. Runs IN the agent's process and
  returns `{:noreply, state}`. `:apply_when_idle` is the internal re-cast that
  defers the relaunch past a running turn.
  """
  def handle_cast(:apply_when_idle, state) do
    if busy?(state) do
      Process.send_after(
        self(),
        {:"$gen_cast", {:set_subagent_model, :apply_when_idle}},
        @retry_ms
      )

      {:noreply, state}
    else
      GenServer.cast(self(), {:restart_session, :settings})
      # "Reconnecting…" in the harness-status block for the relaunch; sends
      # queue behind it (`:backoff` is the queue-and-deliver status).
      state = %{state | status: :backoff}
      :ets.insert(@ets_table, {state.id, Loopyard.ChatAgent.summary(state)})
      Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: :backoff})
      {:noreply, state}
    end
  end

  def handle_cast(model, state) do
    case switch(state, model) do
      {state, :restart} -> handle_cast(:apply_when_idle, state)
      {state, :noop} -> {:noreply, state}
      {state, {:error, reason}} -> refuse(state, model, reason)
    end
  end

  @doc """
  Set `state`'s sub-agent model (`nil` or `""` clears it). Returns
  `{state, :restart | :noop | {:error, reason}}`; refuses a harness without the
  knob and a model that harness doesn't list.
  """
  @spec switch(map(), String.t() | nil) :: {map(), :restart | :noop | {:error, term()}}
  def switch(state, model) do
    model = if model == "", do: nil, else: model
    harness = Loopyard.ChatAgent.HarnessControl.current(state)
    opts = Map.get(state, :session_opts) || []

    cond do
      Keyword.get(opts, :subagent_model) == model ->
        {state, :noop}

      not Catalog.subagent_model?(harness) ->
        {state, {:error, :unsupported}}

      model != nil and not Catalog.subagent_model_valid?(harness, model) ->
        {state, {:error, :unknown_model}}

      true ->
        {apply_setting(state, opts, model), :restart}
    end
  end

  @doc "An agent summary's sub-agent model, or nil."
  def current(summary), do: summary[:subagent_model]

  defp apply_setting(state, opts, model) do
    opts =
      if model,
        do: Keyword.put(opts, :subagent_model, model),
        else: Keyword.delete(opts, :subagent_model)

    state = %{state | session_opts: opts}

    :ets.insert(@ets_table, {state.id, Loopyard.ChatAgent.summary(state)})
    Persistence.persist_agent(state, &Loopyard.ChatAgent.summary/1)
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: state.status})

    Loopyard.EventLog.info(
      "agent:#{state.name}",
      "Sub-agent model set to #{model || "same as the agent"} — relaunching, conversation resumed"
    )

    state
  end

  defp refuse(state, model, reason) do
    Loopyard.EventLog.warning(
      "agent:#{state.name}",
      "Sub-agent model #{inspect(model)} refused: #{inspect(reason)}"
    )

    {:noreply, state}
  end

  defp busy?(state), do: Map.get(state, :status) == :thinking
end
