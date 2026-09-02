defmodule Loopyard.ChatAgent.Client do
  @moduledoc """
  The thin client API for `Loopyard.ChatAgent` — pure call/cast wrappers
  around the agent's Registry `via` tuple (plus the ETS fallbacks the read
  paths use). No GenServer callbacks live here; every public name is
  re-exposed on `Loopyard.ChatAgent` via `defdelegate`, so external callers
  keep saying `ChatAgent.foo`.
  """

  alias Loopyard.ChatAgent.{Lifecycle, MessageWindow}
  alias Loopyard.Events

  @ets_table :chat_agents

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(Loopyard.ChatAgent, opts, name: via(id))
  end

  def send_message(id, text) do
    GenServer.cast(via(id), {:send_message, text})
  end

  @doc """
  Durability-confirmed send for the interactive UI. Unlike `send_message/2`
  (fire-and-forget cast — fine for internal/eval callers), this is a **call**
  that returns `:ok` only AFTER the agent has actually received and processed
  the message (appended + persisted, or durably queued in `pending_sends`).

  Returns `{:error, :unavailable}` when the agent's GenServer is down or dies
  mid-handling. The LiveView send path keys the input-clear on this: no `:ok`,
  no clear — so a message sent into a crashed/reloading agent is NEVER silently
  lost with the box wiped. This closes the "acked before it was safe" gap.
  """
  @spec enqueue_message(String.t(), String.t()) ::
          :ok | {:error, :unavailable | :queue_full}
  def enqueue_message(id, text) do
    GenServer.call(via(id), {:send_message, text}, 15_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def get_state(id) do
    # Try live GenServer first, fall back to ETS. Short timeout (500ms)
    # because this is a read path from the UI: a wedged agent doesn't
    # deserve a 5-second UI hang when the ETS summary is right there.
    # The fall-through via `catch :exit, _` handles both "no such
    # agent" (noproc) and "agent wedged / took >500ms" — both recover
    # cleanly from ETS.
    GenServer.call(via(id), :get_state, 500)
  catch
    :exit, _ ->
      case :ets.lookup(@ets_table, id) do
        [{^id, summary}] -> summary
        [] -> nil
      end
  end

  def stop_agent(id) do
    case Registry.lookup(Loopyard.ChatAgentRegistry, id) do
      [{pid, _}] ->
        # Update ETS and broadcast before stopping, since terminate(:normal) is a no-op
        case :ets.lookup(@ets_table, id) do
          [{^id, summary}] ->
            stopped = %{summary | status: :stopped}
            :ets.insert(@ets_table, {id, stopped})
            Events.ChatAgent.publish(%Events.ChatAgent.Stopped{summary: stopped})

          [] ->
            :ok
        end

        # Force-stop the GenServer (kills linked streaming task too).
        # Guard with Process.alive? so already-dead pids short-circuit
        # — without the guard, GenServer.stop/3 on a noproc raises an
        # exit that callers have to rescue. Matters most for AgentBoot
        # rollback, where the agent is often already dying; the stop
        # used to wait 5s for a no-op.
        if Process.alive?(pid) do
          GenServer.stop(pid, :normal, 5_000)
        else
          :ok
        end

      [] ->
        :ok
    end
  end

  def rename(id, new_name) do
    GenServer.cast(via(id), {:rename, new_name})
  end

  @doc "Get a specific message by ID from the agent's ETS state."
  def get_message(agent_id, msg_id) do
    case get_state(agent_id) do
      %{messages: messages} -> Enum.find(messages, &(&1[:id] == msg_id))
      _ -> nil
    end
  end

  @doc """
  Get a page of messages for an agent. Returns `{messages_slice, total_count}`.

  Delegates to `Loopyard.ChatAgent.MessageWindow` (ETS-backed pagination).
  """
  def get_messages(agent_id, opts \\ []), do: MessageWindow.get_messages(agent_id, opts)

  @doc """
  Restart the CLI session without losing the agent or its messages.

  `reason` decides what the CHAT says about it — a real crash recovery is
  worth a marker; deliberate maintenance is not (the user asked why their
  healthy idle agent kept announcing "CLI crashed" — it was credential
  reloads):

    * `:user` — someone clicked Restart; confirm with a quiet marker.
    * `:reload` — someone clicked "Restart agent" wanting a FULL restart:
      rebuild session_opts first (fresh MCP tool config + a system prompt
      re-read from disk) so a dropped/changed tool comes back, THEN restart
      like `:user` (conversation kept). This is the button's reason.
    * `:credentials` — token pushed (`Workstation.reload_agents`); silent.
    * `:memory_reclaim` — MemoryMonitor reclaiming an idle bloated harness;
      silent (it already EventLogs the why).
    * `:harness` — the user picked a different harness (Claude → Codex);
      confirm with a marker, since the switch is theirs and the reply will
      come from somewhere new.
    * `:recovery` — actual crash recovery (internal casts); keeps the loud
      marker.
  """
  def restart_session(id, reason \\ :user)
      when reason in [:user, :reload, :credentials, :memory_reclaim, :recovery, :harness] do
    GenServer.cast(via(id), {:restart_session, reason})
  end

  @doc "Switch the agent's model (Usage-panel Model row); see ChatAgent.ModelControl."
  def set_model(id, model_id) when is_binary(model_id),
    do: GenServer.cast(via(id), {:set_model, model_id})

  @doc """
  Switch the agent to a different harness (Claude → Codex). Restarts the
  session; the conversation is carried over from Loopyard's durable log.
  See `ChatAgent.HarnessControl`.
  """
  def set_harness(id, harness_id, model \\ nil),
    do: GenServer.cast(via(id), {:set_harness, harness_id, model})

  @doc "Register an agent as booting in ETS so all viewers can see it"
  def register_booting(id, name, working_dir, opts \\ []),
    do: Lifecycle.register_booting(id, name, working_dir, opts)

  def subscribe do
    Loopyard.Events.ChatAgent.subscribe()
  end

  def subscribe(agent_id) do
    Loopyard.Events.ChatAgentMessage.subscribe(agent_id)
  end

  def unsubscribe(agent_id) do
    Loopyard.Events.ChatAgentMessage.unsubscribe(agent_id)
  end

  @doc "Drop all queued (pending) messages without stopping the current turn."
  def clear_pending(id), do: GenServer.cast(via(id), :clear_pending)

  @doc "Warm-interrupt the in-flight turn (keep the session); sleep the agent if idle."
  def interrupt(id), do: GenServer.cast(via(id), :interrupt)

  @doc "Remove a single queued message by its index in the pending queue."
  def remove_pending(id, index) when is_integer(index),
    do: GenServer.cast(via(id), {:remove_pending, index})

  @doc """
  Edit a queued message IN PLACE — replace it with `new_text` at its position,
  never re-appending to the end (which reordered the queue on every edit). Guarded
  by `old_text` so a queue that shifted under the edit (another line removed, or a
  drain) can't clobber the wrong message.
  """
  def update_pending(id, index, old_text, new_text)
      when is_integer(index) and is_binary(old_text) and is_binary(new_text),
      do: GenServer.cast(via(id), {:update_pending, index, old_text, new_text})

  defp via(id), do: {:via, Registry, {Loopyard.ChatAgentRegistry, id}}
end
