defmodule Loopyard.ChatAgent.Interrupted do
  @moduledoc """
  An agent a server restart cut off mid-turn (#119), as plain code. Runs IN the
  agent's process; state in, state out.

  The row comes back from the log at rest and marked `interrupted?: true`
  (`Loopyard.AgentLog.at_rest/1`). `on_resume/2` carries that mark into the
  resumed agent's state, and then:

    * **Recent** (last activity within `:interrupted_resume_window_ms`, default
      30 minutes) and the harness session is up → re-drive the unanswered
      prompts ONCE, by putting them at the head of the pending queue (the same
      queue-and-deliver `ChatAgent.PlanLimit` and the harness recycle use), with
      one quiet system line. The mark is dropped.
    * **Old**, or no live session (its work container isn't up) → keep the mark.
      `Loopyard.Fleet.Watch` raises it as an inbox item offering Continue
      (`continue/1`) and Dismiss (`dismiss/1`).
    * **Already answered** (the last message is an assistant reply) → nothing to
      continue; the mark is dropped.

  Never twice for one interruption: the mark goes the moment the prompts are
  queued, and a turn that a SECOND restart cuts off before any reply (the line
  below is still the newest thing after the user's prompt) is not auto-driven
  again — a prompt that keeps killing the server must not loop.
  """

  alias Loopyard.ChatAgent.{MessageLog, Persistence, Restart}
  alias Loopyard.Events

  @ets_table :chat_agents

  @line "Picked up where the restart cut it off."

  @doc "The one system line a re-driven interruption leaves in the chat."
  def line, do: @line

  @doc "Is the agent carrying an unfinished interruption?"
  def marked?(state), do: Map.get(state, :interrupted?) == true

  @doc """
  Called from `Initializer` on resume with the saved row. Returns the state to
  boot with: the prompts queued (recent), the mark kept (old / no session), or
  the mark dropped (nothing to continue).
  """
  @spec on_resume(map(), map()) :: map()
  def on_resume(state, saved) do
    cond do
      saved[:interrupted?] != true -> state
      Restart.pending_user_prompts(state) == [] -> state
      recent?(saved) and session_up?(state) and not already_redriven?(state) -> redrive(state)
      true -> Map.put(state, :interrupted?, true)
    end
  end

  @doc """
  The `{:interrupted, :continue}` call — Continue from the inbox, or the chief
  of staff's `agent action=continue`. Idle only; re-drives the unanswered
  prompts whether or not the agent was marked (a human or the chief of staff
  asked for it explicitly).
  """
  def handle(:continue, state) do
    cond do
      state.status != :idle ->
        {:reply, {:error, :busy}, state}

      Restart.pending_user_prompts(state) == [] ->
        {:reply, {:error, :nothing_to_continue}, publish(Map.delete(state, :interrupted?))}

      true ->
        state = redrive(state)
        send(self(), :drain_resumed_pending)
        {:reply, :ok, publish(state)}
    end
  end

  def handle(:dismiss, state), do: {:reply, :ok, publish(Map.delete(state, :interrupted?))}

  def handle(_other, state), do: {:reply, {:error, :unknown}, state}

  @doc """
  Clear the mark of an agent with no process (asleep): rewrite its row and log
  it, so the next boot's `at_rest/1` doesn't mark it again.
  """
  @spec clear_row(map()) :: :ok
  def clear_row(%{id: id} = row) do
    row = row |> Map.put(:interrupted?, false) |> Map.put(:status, :idle)
    :ets.insert(@ets_table, {id, row})
    Persistence.persist_agent(row, & &1)
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: id, status: :idle})
    :ok
  rescue
    _ -> :ok
  end

  @doc "Was the agent's last activity within the resume window?"
  @spec recent?(map(), integer()) :: boolean()
  def recent?(row, now_ms \\ System.system_time(:millisecond)) do
    case last_activity_ms(row) do
      nil -> false
      at -> now_ms - at <= window_ms()
    end
  end

  @doc "The latest of the row's last activity and its newest message, in ms."
  def last_activity_ms(row) do
    stamps =
      [row[:last_activity_at] | Enum.map(List.wrap(row[:messages]), & &1[:timestamp])]
      |> Enum.filter(&match?(%DateTime{}, &1))

    case stamps do
      [] -> nil
      list -> list |> Enum.max(DateTime) |> DateTime.to_unix(:millisecond)
    end
  end

  defp window_ms, do: Application.get_env(:loopyard, :interrupted_resume_window_ms, 30 * 60_000)

  defp session_up?(state) do
    state.backend.session_alive?(state.session)
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # Newest first: did a re-drive line land after the unanswered prompts, with
  # no reply since? Then a restart cut off the re-drive itself.
  defp already_redriven?(state) do
    state.messages
    |> Enum.take_while(&(not (&1[:role] == :assistant and &1[:partial] != true)))
    |> Enum.any?(&(&1[:role] == :system and &1[:content] == @line))
  end

  defp redrive(state) do
    # Consecutive duplicates: a re-drive cut off again re-commits the prompt.
    prompts = Enum.dedup(Restart.pending_user_prompts(state))

    state
    |> Map.delete(:interrupted?)
    |> Map.update!(:pending_sends, &(prompts ++ &1))
    |> append_line()
  end

  defp append_line(state) do
    msg = %{role: :system, content: @line, timestamp: DateTime.utc_now()}
    {state, msg} = MessageLog.append(state, msg)
    Persistence.persist_message(state, msg)

    Events.ChatAgentMessage.publish(%Events.ChatAgentMessage.Message{
      agent_id: state.id,
      msg: msg
    })

    state
  end

  defp publish(state) do
    summary = Loopyard.ChatAgent.summary(state)
    :ets.insert(@ets_table, {state.id, summary})
    Persistence.persist_agent(state, &Loopyard.ChatAgent.summary/1)
    Events.ChatAgent.publish(%Events.ChatAgent.StatusChanged{id: state.id, status: state.status})
    state
  end
end
