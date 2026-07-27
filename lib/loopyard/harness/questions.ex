defmodule Loopyard.Harness.Questions do
  @moduledoc """
  The harness↔user question broker — harness-agnostic.

  A harness entry point (the `ask_user` MCP tool for the custom Claude backend
  today; an ACP `session/request_permission` handler later) calls `ask/2` with
  normalized questions (produced by a `Loopyard.Harness.QuestionAdapter`). The
  broker:

    1. appends a `role: :question` message to the agent's stream
       (`ChatAgent.append_message_ets`) — which broadcasts to **every** viewer,
       so the interactive card shows up for the whole room (multiplayer).
    2. records the pending question in ETS, keyed by `question_id`, holding the
       **caller's pid** as the waiter.
    3. blocks the caller on `receive` until someone answers (or it times out).

  The UI calls `answer/2` when a human clicks; that delivers the selections to
  the blocked waiter and flips the message to `:answered` for everyone via
  `ChatAgent.update_message`.

  Because the call blocks, this reads like the synchronous "ask and wait for the
  callback" the harness wants: `{:ok, selections} = Questions.ask(agent_id, qs)`.
  """
  alias Loopyard.ChatAgent

  @table :harness_questions
  # Keep under the ChatAgent stream timeout so a never-answered question doesn't
  # wedge the agent's turn forever.
  @timeout_ms 10 * 60 * 1000

  @type selections :: %{optional(String.t()) => [String.t()]}

  @doc """
  Ask `questions` (normalized list) and BLOCK until answered. Returns
  `{:ok, selections}` or `{:error, :timeout}`. Run from the harness entry point's
  process (it's the one that blocks + receives the answer).
  """
  @spec ask(String.t(), [map()]) :: {:ok, selections()} | {:error, :timeout}
  def ask(agent_id, questions, source \\ nil)
      when is_binary(agent_id) and is_list(questions) do
    qid = gen_id()

    msg =
      ChatAgent.append_message_ets(agent_id, %{
        role: :question,
        question_id: qid,
        questions: questions,
        # A memo's attribution — "project · workspace" this decision is about.
        # nil for questions asked without a source (workspace agents' own asks).
        source: source,
        status: :pending,
        timestamp: DateTime.utc_now()
      })

    msg_id = msg && msg.id

    :ets.insert(
      @table,
      {qid, %{agent_id: agent_id, msg_id: msg_id, waiter: self(), questions: questions}}
    )

    # Signal "the agent needs YOU" so the chime bridge can play its distinct
    # attention sound (vs the turn-finished "done" chime). Observability only —
    # crash-safe, no-op if activity/sound is off.
    Loopyard.Events.Activity.record(agent_id, :status, :awaiting)

    receive do
      {:answered, ^qid, selections} ->
        :ets.delete(@table, qid)
        update_msg(agent_id, msg_id, %{status: :answered, selections: selections})
        {:ok, selections}
    after
      @timeout_ms ->
        :ets.delete(@table, qid)
        update_msg(agent_id, msg_id, %{status: :timeout})
        {:error, :timeout}
    end
  end

  @doc """
  Deliver a human's answer to a pending question. Called from the LiveView.
  `selections` is `%{question_id => [chosen_label, ...]}`. Idempotent-ish: a
  second answer for an already-resolved question is a no-op.

  Resolves the WHOLE ask at once — used by `answer_with_text/2` (typed chat
  answers everything). Button clicks go through `answer_partial/3` instead,
  which resolves only when EVERY question has been answered or skipped.
  """
  @spec answer(String.t(), selections()) :: :ok | {:error, :not_found}
  def answer(qid, selections) when is_binary(qid) and is_map(selections) do
    case :ets.lookup(@table, qid) do
      [{^qid, %{waiter: pid}}] when is_pid(pid) ->
        send(pid, {:answered, qid, selections})
        :ok

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Record ONE question's answer (and mark it done) without resolving the rest.

  This is what the card's buttons call. A multi-question ask used to resolve on
  the FIRST click — the remaining questions were returned to the harness as
  "(no answer)" and shown as answered, which is exactly the "I answered one and
  the rest got marked answered" bug. Now each question locks in independently
  (broadcast to every viewer via the message update) and the blocked harness
  call resolves only when the last question is answered or skipped.

  `labels == []` means the user skipped this question.
  """
  @spec answer_partial(String.t(), String.t(), [String.t()]) :: :ok | {:error, :not_found}
  def answer_partial(qid, q_id, labels) when is_binary(qid) and is_list(labels) do
    with_entry(qid, fn entry ->
      entry
      |> put_selection(q_id, labels)
      |> mark_done(q_id)
    end)
  end

  @doc """
  Toggle one option label in a multi-select question's draft selection.
  Does NOT mark the question done — `confirm_question/2` does that. The draft
  lives on the broker entry + message (broadcast), so every viewer sees the
  toggles (multiplayer), and a refresh doesn't lose them.
  """
  @spec toggle_option(String.t(), String.t(), String.t()) :: :ok | {:error, :not_found}
  def toggle_option(qid, q_id, label) when is_binary(qid) and is_binary(label) do
    with_entry(qid, fn entry ->
      if q_id in (entry[:done] || []) do
        entry
      else
        current = Map.get(entry[:selections] || %{}, q_id, [])

        toggled =
          if label in current, do: List.delete(current, label), else: current ++ [label]

        put_selection(entry, q_id, toggled)
      end
    end)
  end

  @doc """
  Draft ONE option for a single-select question (replaces any prior draft) —
  broadcast so every viewer sees the highlight, but nothing commits until
  `commit_draft/2`. The tap-to-highlight half of tap → Answer.
  """
  def draft_option(qid, q_id, label) when is_binary(qid) and is_binary(label) do
    with_entry(qid, fn entry ->
      if q_id in (entry[:done] || []), do: entry, else: put_selection(entry, q_id, [label])
    end)
  end

  @doc """
  Commit the drafted selection — the Answer button. NO-OP when nothing is
  drafted (an empty commit is not a skip; Skip is explicit).
  """
  def commit_draft(qid, q_id) when is_binary(qid) and is_binary(q_id) do
    committed = :counters.new(1, [])

    result =
      with_entry(qid, fn entry ->
        case Map.get(entry[:selections] || %{}, q_id, []) do
          [] ->
            entry

          drafted ->
            :counters.add(committed, 1, 1)
            entry |> put_selection(q_id, drafted) |> mark_done(q_id)
        end
      end)

    cond do
      result != :ok -> result
      :counters.get(committed, 1) > 0 -> :ok
      # Nothing drafted: tell the caller so the UI can say "pick one first"
      # instead of a silent no-op that reads as a broken button.
      true -> :noop
    end
  end

  @doc "Confirm a multi-select question's current draft (possibly empty = skip) as its answer."
  @spec confirm_question(String.t(), String.t()) :: :ok | {:error, :not_found}
  def confirm_question(qid, q_id) when is_binary(qid) and is_binary(q_id) do
    with_entry(qid, fn entry ->
      entry
      |> put_selection(q_id, Map.get(entry[:selections] || %{}, q_id, []))
      |> mark_done(q_id)
    end)
  end

  # Read-modify-write an entry, broadcast the new partial state onto the card's
  # message, and resolve the blocked waiter once every question is done.
  # (Concurrent clicks from two viewers race the read-modify-write; the window
  # is milliseconds and the loser's toggle is re-clickable — accepted.)
  defp with_entry(qid, fun) do
    case :ets.lookup(@table, qid) do
      [{^qid, entry}] ->
        entry = fun.(entry)
        :ets.insert(@table, {qid, entry})

        update_msg(entry.agent_id, entry.msg_id, %{
          selections: entry[:selections] || %{},
          done: entry[:done] || []
        })

        if length(entry[:done] || []) >= length(entry.questions) do
          if is_pid(entry[:waiter]) and Process.alive?(entry.waiter) do
            send(entry.waiter, {:answered, qid, entry[:selections] || %{}})
          else
            # Waiter long gone (queued model): the answer still REACHES the
            # agent — resolve the card and enqueue the selections as a message.
            deliver_late_answer(qid, entry)
          end
        end

        :ok

      _ ->
        # No broker entry (pruned/restart) but the CARD is durable — rebuild
        # the entry from the pending message so answering always works.
        case rebuild_entry(qid) do
          nil ->
            {:error, :not_found}

          entry ->
            :ets.insert(@table, {qid, entry})
            with_entry(qid, fun)
        end
    end
  end

  # Find the pending :question card carrying this question_id across agents and
  # reconstruct a waiterless broker entry from its durable state.
  defp rebuild_entry(qid) do
    # Pure-ETS summaries (list_agents/0 pays a 500ms GenServer call per live
    # agent — inside a LiveView handle_event that blocked the LV for seconds
    # under load). Card status/selections are written through to ETS on every
    # update, so the summary is fresh enough to rebuild from.
    Enum.find_value(ChatAgent.list_agent_summaries(), fn %{id: aid} = st ->
      # Tail-capped like Attention.line/0: pending cards live near the tail,
      # and this runs inside a LiveView handle_event — a full-fleet full-history
      # scan on a stale card id blocked the LV for seconds under load.
      (Map.get(st, :messages) || [])
      |> Enum.take(-200)
      |> Enum.find(
        &(&1[:role] == :question and &1[:question_id] == qid and &1[:status] == :pending)
      )
      |> case do
        nil ->
          nil

        msg ->
          %{
            agent_id: aid,
            msg_id: msg.id,
            questions: msg[:questions] || [],
            selections: msg[:selections] || %{},
            done: msg[:done] || [],
            waiter: nil
          }
      end
    end)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp deliver_late_answer(qid, entry) do
    update_msg(entry.agent_id, entry.msg_id, %{status: :answered})
    :ets.delete(@table, qid)

    answer_text =
      (entry[:selections] || %{})
      |> Enum.map_join("; ", fn {q_id, labels} ->
        q = Enum.find(entry.questions, &(&1.id == q_id))
        "#{(q && q.prompt) || q_id}: #{Enum.join(labels, ", ")}"
      end)

    ChatAgent.enqueue_message(
      entry.agent_id,
      "Answer to your earlier question — " <> answer_text
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp put_selection(entry, q_id, labels),
    do: Map.put(entry, :selections, Map.put(entry[:selections] || %{}, q_id, labels))

  defp mark_done(entry, q_id),
    do: Map.put(entry, :done, Enum.uniq((entry[:done] || []) ++ [q_id]))

  @doc "Is this question still awaiting an answer?"
  @spec pending?(String.t()) :: boolean()
  def pending?(qid), do: :ets.member(@table, qid)

  @doc """
  The pending question for `agent_id`, if any: `{qid, entry}` or `nil`.
  An agent blocks on at most one `ask_user` call at a time, so there's
  one entry to find. Small table (a handful of in-flight questions), so
  a linear scan is fine.
  """
  @spec pending_for_agent(String.t()) :: {String.t(), map()} | nil
  def pending_for_agent(agent_id) when is_binary(agent_id) do
    :ets.tab2list(@table)
    |> Enum.filter(fn {_qid, entry} -> entry.agent_id == agent_id end)
    |> Enum.find_value(fn {qid, entry} ->
      # A question is only really pending if its waiter (the blocked
      # harness tool process) is still alive. If the tool died abnormally
      # (session restart, stream replaced, CLI crash) the receive in
      # ask/2 never ran, so the entry leaked. Reap it here — and flip the
      # card off "Asking…" — so a dead question can't hijack a chat
      # message (route it to a dead pid = silently lost).
      if Process.alive?(entry.waiter) do
        {qid, entry}
      else
        :ets.delete(@table, qid)
        update_msg(entry.agent_id, entry.msg_id, %{status: :timeout})
        nil
      end
    end)
  end

  @doc "Whether `agent_id` is currently blocked awaiting a question answer."
  @spec pending_for_agent?(String.t()) :: boolean()
  def pending_for_agent?(agent_id), do: pending_for_agent(agent_id) != nil

  @doc """
  Cancel an agent's leaked/orphaned pending question: kill the still-blocked
  waiter Task, drop the ETS entry, and flip the card to :timeout. Used when the
  agent is idle but a question still reports pending — the harness abandoned the
  elicitation (its own shorter timeout) while our `ask/2` kept blocking for its
  full window, so the "pending" question can never be usefully answered. Killing
  the waiter is safe: its consumer (the ACP elicitation request) already gave up,
  so it would only cast a result nobody's waiting for. No-op if nothing's pending.
  """
  @spec cancel_for_agent(String.t()) :: :ok
  def cancel_for_agent(agent_id) when is_binary(agent_id) do
    case pending_for_agent(agent_id) do
      {qid, entry} ->
        if is_pid(entry.waiter) and Process.alive?(entry.waiter),
          do: Process.exit(entry.waiter, :kill)

        :ets.delete(@table, qid)
        update_msg(agent_id, entry.msg_id, %{status: :timeout})
        :ok

      nil ->
        :ok
    end
  end

  @doc """
  Every live pending question across ALL agents — the town-hall line. Reaps
  dead/leaked entries (waiter no longer alive) as it scans, so the result only
  ever holds questions still blocking a live tool. Small table; linear scan.
  """
  @spec pending_all() :: [{String.t(), map()}]
  def pending_all do
    :ets.tab2list(@table)
    |> Enum.filter(fn {qid, entry} ->
      cond do
        is_pid(entry.waiter) and Process.alive?(entry.waiter) ->
          true

        # Waiter gone (ACP elicitation gives up in ~60s) but the CARD is still
        # :pending — the agent hasn't moved on, so the question is still
        # RELEVANT and must stay in the attention line ("For you"). Relevance
        # is card state, not waiter liveness: cancel_for_agent flips the card
        # to :timeout when the agent moves past it, and THAT is when it drops.
        card_pending?(entry) ->
          true

        true ->
          :ets.delete(@table, qid)
          false
      end
    end)
  end

  defp card_pending?(entry) do
    match?(%{status: :pending}, Loopyard.ChatAgent.get_message(entry.agent_id, entry.msg_id))
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc """
  Resolve an agent's pending question with free-text the user typed into
  chat (instead of clicking a button). Maps the text onto every question
  in the pending call as the chosen answer, so the blocked harness turn
  unblocks with the user's actual words. No-op (`{:error, :none_pending}`)
  if nothing's pending. This is what makes "just chat at the agent while
  it's asking" work instead of deadlocking the turn.
  """
  @spec answer_with_text(String.t(), String.t()) :: :ok | {:error, :none_pending}
  def answer_with_text(agent_id, text) when is_binary(agent_id) and is_binary(text) do
    case pending_for_agent(agent_id) do
      {qid, %{questions: questions} = entry} ->
        # Keep any answers already locked in via the card's buttons — the typed
        # text answers only the questions still open.
        existing = entry[:selections] || %{}
        done = entry[:done] || []

        selections =
          Map.new(questions, fn q ->
            if q.id in done, do: {q.id, Map.get(existing, q.id, [])}, else: {q.id, [text]}
          end)

        answer(qid, selections)

      _ ->
        {:error, :none_pending}
    end
  end

  # --- internals ---

  defp update_msg(_agent_id, nil, _changes), do: :ok

  defp update_msg(agent_id, msg_id, changes) do
    # update_message_NOW: card state must render instantly for every viewer —
    # the plain cast rides the agent's mailbox, which during a streaming turn
    # made a draft tap take seconds to highlight.
    Loopyard.ChatAgent.MessageWindow.update_message_now(agent_id, msg_id, fn m ->
      Map.merge(m, changes)
    end)
  end

  defp gen_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
