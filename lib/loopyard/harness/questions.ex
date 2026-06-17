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
  require Logger

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
  def ask(agent_id, questions) when is_binary(agent_id) and is_list(questions) do
    qid = gen_id()

    msg =
      ChatAgent.append_message_ets(agent_id, %{
        role: :question,
        question_id: qid,
        questions: questions,
        status: :pending,
        timestamp: DateTime.utc_now()
      })

    msg_id = msg && msg.id

    :ets.insert(
      @table,
      {qid, %{agent_id: agent_id, msg_id: msg_id, waiter: self(), questions: questions}}
    )

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
      {qid, %{questions: questions}} ->
        selections = Map.new(questions, fn q -> {q.id, [text]} end)
        answer(qid, selections)

      _ ->
        {:error, :none_pending}
    end
  end

  # --- internals ---

  defp update_msg(_agent_id, nil, _changes), do: :ok

  defp update_msg(agent_id, msg_id, changes) do
    ChatAgent.update_message(agent_id, msg_id, fn m -> Map.merge(m, changes) end)
  end

  defp gen_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
