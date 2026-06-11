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
    :ets.insert(@table, {qid, %{agent_id: agent_id, msg_id: msg_id, waiter: self()}})

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

  # --- internals ---

  defp update_msg(_agent_id, nil, _changes), do: :ok

  defp update_msg(agent_id, msg_id, changes) do
    ChatAgent.update_message(agent_id, msg_id, fn m -> Map.merge(m, changes) end)
  end

  defp gen_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
