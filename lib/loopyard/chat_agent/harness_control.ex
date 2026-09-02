defmodule Loopyard.ChatAgent.HarnessControl do
  @moduledoc """
  Harness switching for a ChatAgent — the sidebar picker's "run this agent on
  Codex instead" row.

  Unlike `ModelControl`, this can't be applied to the live session: a harness is
  a different adapter process entirely. So `switch/2` persists the choice into
  `session_opts` and asks for a restart; `Restart.restart_session_now/2` handles
  the rest.

  **The conversation survives the switch.** The native session id is dropped
  (Codex cannot resume a Claude session — the id is meaningless to it), which
  routes the restart down the already-built rebuild-from-history path:
  `ResumeMessage` seeds the fresh session with recent turns and the agent can
  pull more with `recall_conversation`. That machinery is why Loopyard owns the
  durable message inbox rather than delegating memory to the harness — this is
  the payoff.

  A no-op switch (same harness) is deliberately NOT a restart: users click the
  row they're already on, and tearing down a working session for that would be
  a surprising, expensive nothing.
  """

  alias Loopyard.ChatAgent.Persistence
  alias Loopyard.Events
  alias Loopyard.Harness.Catalog

  @ets_table :chat_agents

  @doc """
  The `{:set_harness, …}` cast body. Runs IN the agent's process (it self-casts
  the restart) and returns the `{:noreply, state}` shape the callback returns
  as-is — same contract as the other ChatAgent helper modules.
  """
  def handle_switch(state, harness_id, model \\ nil) do
    case switch(state, harness_id, model) do
      {state, :restart} ->
        GenServer.cast(self(), {:restart_session, :harness})
        {:noreply, state}

      {state, :noop} ->
        {:noreply, state}
    end
  end

  @doc """
  Switch `state` to `harness_id`. Returns `{state, :restart | :noop}` — the
  caller casts the restart, so this stays a pure-ish state transition.
  """
  def switch(state, harness_id, model \\ nil) do
    target = Catalog.fetch(harness_id)
    current = Catalog.fetch(Keyword.get(Map.get(state, :session_opts) || [], :harness))

    if target.id == current.id do
      {state, :noop}
    else
      state = %{
        state
        | session_opts:
            Map.get(state, :session_opts)
            |> Kernel.||([])
            |> Keyword.put(:harness, target.id)
            # The model travels with the harness. Carrying Claude's model id
            # across would hand "claude-opus-4-8" to codex-acp, whose set_model
            # rejects it — the agent would fail to start on a model the user
            # never chose. An explicit `model` (the picker sends one when the
            # target harness has a pinned list) replaces it; otherwise drop it
            # and let the new adapter boot on its own default.
            |> put_or_delete_model(model),
          model: model
      }

      :ets.insert(@ets_table, {state.id, Loopyard.ChatAgent.summary(state)})
      Persistence.persist_agent(state, &Loopyard.ChatAgent.summary/1)

      Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{
        id: state.id,
        status: state.status
      })

      Loopyard.EventLog.info(
        "agent:#{state.name}",
        "Harness switched to #{target.label} — restarting, conversation carried over"
      )

      {state, :restart}
    end
  end

  @doc """
  The harness an agent is currently running on (never nil).

  `Map.get`, not `state.session_opts`: this is called from `Summary.build/1`,
  which also runs over partial state maps (tests, and any struct written before
  a field existed). A strict fetch here turns a missing key into a KeyError in
  the summary path — i.e. in ETS writes and broadcasts.
  """
  def current(state),
    do: Catalog.fetch(Keyword.get(Map.get(state, :session_opts) || [], :harness)).id

  @doc """
  The ONE chat error for a harness that can't sign in, WHY / CONSEQUENCE /
  ACTION. Every spawn-failure site (crash recovery, backoff retry, compaction
  restart) hands an `{:auth_failed, error}` reason here instead of its own
  generic copy: "send another message to retry" is not an action when there
  is no credential — it fails identically forever — and an agent running
  Codex must never be told to check `claude`. The fix lives on the
  Workstation page, so that's where this points.
  """
  def auth_failed_copy(state, error) do
    harness = Catalog.fetch(current(state))

    "#{harness.label} isn't signed in in this box (#{auth_detail(error)}). " <>
      "CONSEQUENCE: this agent can't run until it is; your messages are preserved. " <>
      "ACTION: connect #{harness.label} on the Workstation page — set " <>
      "#{Enum.join(harness.credential_keys, " or ")}, or run its login command in the " <>
      "box console — then click Restart."
  end

  defp auth_detail(%{"message" => m}) when is_binary(m),
    do: String.replace_prefix(m, "Internal error: ", "")

  defp auth_detail(other), do: inspect(other)

  defp put_or_delete_model(session_opts, nil), do: Keyword.delete(session_opts, :model)
  defp put_or_delete_model(session_opts, model), do: Keyword.put(session_opts, :model, model)
end
