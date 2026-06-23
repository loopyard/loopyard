defmodule Loopyard.Harness.SecretRequests do
  @moduledoc """
  The harness↔user **secret** broker — the secure sibling of
  `Loopyard.Harness.Questions`.

  When an agent needs a secret it doesn't have (an API key, a token), the
  `request_secret` MCP tool calls `request/3`. The broker:

    1. appends a `role: :secret_request` message to the agent's stream — which
       broadcasts to **every** viewer, so the masked-input card shows up for the
       whole room (multiplayer). The message carries only the NAME and status,
       never a value.
    2. records the pending request in ETS, keyed by `request_id`, holding the
       **caller's pid** as the waiter.
    3. blocks the caller on `receive` until someone submits (or it times out).

  The crucial difference from `Questions`: **the value never travels to the
  waiter.** The UI calls `submit/4`, which writes the value straight to the
  on-disk secret store (`Loopyard.Secrets.put/4`, scoped to the workspace) from
  the LiveView process, then signals the waiter with only the secret's KEY. So
  the value's path is browser → LiveView → disk; it never enters the chat
  transcript, never rides PubSub to other viewers, and never lands in the agent's
  tool-call result. The agent gets back a key it can later read with `get_secret`
  (the deliberate, documented boundary — see docs/SECURITY.md).
  """
  require Logger

  alias Loopyard.ChatAgent
  alias Loopyard.Secrets

  @table :secret_requests
  # Match the question timeout — long enough for a human to fetch a key, short
  # enough that an abandoned request doesn't wedge the agent's turn forever.
  @timeout_ms 10 * 60 * 1000

  @doc """
  Request a secret named `name` (with an optional `why`) and BLOCK until it's
  submitted. Returns `{:ok, key}` (the storage key the agent can later
  `get_secret`) or `{:error, :timeout}`. Run from the tool's process — it's the
  one that blocks + receives the signal.
  """
  @spec request(String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :timeout}
  def request(agent_id, name, why \\ nil) when is_binary(agent_id) and is_binary(name) do
    rid = gen_id()
    key = normalize_key(name)

    msg =
      ChatAgent.append_message_ets(agent_id, %{
        role: :secret_request,
        request_id: rid,
        name: name,
        key: key,
        why: why,
        status: :pending,
        timestamp: DateTime.utc_now()
      })

    msg_id = msg && msg.id

    :ets.insert(
      @table,
      {rid, %{agent_id: agent_id, msg_id: msg_id, waiter: self(), name: name, key: key}}
    )

    receive do
      # submit/4 already stored the value and flipped the card to :submitted for
      # everyone — the waiter just resumes the agent's turn with the key.
      {:submitted, ^rid, _submitter} ->
        {:ok, key}
    after
      @timeout_ms ->
        :ets.delete(@table, rid)
        update_msg(agent_id, msg_id, %{status: :timeout})
        {:error, :timeout}
    end
  end

  @doc """
  Submit a secret value for a pending request. Called from the LiveView when a
  human fills the masked field. Writes the value to the on-disk store scoped to
  `workspace_id`, then signals the waiter with the KEY only — the value is never
  sent to the waiter, broadcast, or returned here. `submitter` is a label shown
  on the card (who provided it); the value is intentionally absent from the
  return so a careless caller can't echo it.

  Returns `{:ok, key}` on success, `{:error, :not_found}` if nothing's pending.

  The store + the card flip happen HERE (not in the waiter), so a submitted secret
  is saved and shows as "Submitted" on EVERY viewer even if the requesting tool
  process already died (CLI crash / stream replaced). The waiter is only signalled
  to resume the agent's turn when it's still alive.
  """
  @spec submit(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, String.t()} | {:error, :not_found}
  def submit(rid, value, workspace_id, submitter \\ nil)
      when is_binary(rid) and is_binary(value) do
    case :ets.lookup(@table, rid) do
      [{^rid, %{waiter: pid, name: name, key: key, agent_id: agent_id, msg_id: msg_id}}] ->
        scope = if is_binary(workspace_id), do: [workspace_id], else: []
        Secrets.put(key, name, value, scope)
        :ets.delete(@table, rid)

        # Flip the card to :submitted for EVERY viewer (multiplayer broadcast),
        # independent of waiter liveness — so all UIs know a secret was submitted
        # (never the value).
        update_msg(agent_id, msg_id, %{status: :submitted, submitted_by: submitter})

        # Resume the blocked agent turn only if its waiter is still alive.
        if is_pid(pid) and Process.alive?(pid), do: send(pid, {:submitted, rid, submitter})

        {:ok, key}

      _ ->
        {:error, :not_found}
    end
  end

  @doc "Is this secret request still awaiting a value?"
  @spec pending?(String.t()) :: boolean()
  def pending?(rid), do: :ets.member(@table, rid)

  # --- internals ---

  defp update_msg(_agent_id, nil, _changes), do: :ok

  defp update_msg(agent_id, msg_id, changes) do
    ChatAgent.update_message(agent_id, msg_id, fn m -> Map.merge(m, changes) end)
  end

  # A human-typed name → a stable storage key (what `get_secret` takes).
  defp normalize_key(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp gen_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
