defmodule Loopyard.Fleet.Conditions do
  @moduledoc """
  What can be wrong with an agent that nobody asked about (#119), as pure
  functions over agent summaries — `Loopyard.Fleet.Watch` is only the clock
  and the store writes around them.

  One condition per agent at a time (the most decisive one), each in the same
  words everywhere it shows: the inbox item, the Agents row, the chief of
  staff's wake message and `overview`.

    * `:quarantined` — crash-looped and `ChatAgent.RestartController` stopped
      restarting it.
    * `:signed_out` — its account's sign-in expired (`auth_error`, which
      persists across the self-heal retries that flip the status back to idle).
    * `:offline` — its harness is down (`:crashed`, or `:backoff` retrying)
      past a longer grace period, since a backoff usually heals in seconds.
    * `:failed_turn` — a human's turn failed after its retries and nothing
      will retry it: the stream handler parks the prompt in `failed_prompt`
      and goes idle. Cleared by the next human turn.
    * `:interrupted` — a restart cut its last turn off and nothing continued
      it (`ChatAgent.Interrupted`).

  A wedged turn is not a condition of its own: the stall watchdog ends it,
  and its prompt then sits unanswered like any other failed turn.
  """

  alias Loopyard.ChatAgent.Thread

  @type t :: :interrupted | :signed_out | :quarantined | :failed_turn | :offline

  @doc "Every condition, most decisive first."
  def all, do: [:quarantined, :signed_out, :offline, :failed_turn, :interrupted]

  @doc "The one condition an agent summary is in, or nil."
  @spec of(map()) :: t() | nil
  def of(s) when is_map(s) do
    status = s[:status]

    cond do
      status in [:stopped, :destroying] -> nil
      s[:quarantined] == true -> :quarantined
      status == :auth_expired or is_binary(s[:auth_error]) -> :signed_out
      status in [:crashed, :backoff] -> :offline
      is_binary(s[:failed_prompt]) and status == :idle -> :failed_turn
      s[:interrupted?] == true and status in [:idle, nil] -> :interrupted
      true -> nil
    end
  end

  def of(_), do: nil

  # ── grace + diff ────────────────────────────────────────────────────────

  @doc """
  How long a condition must hold before it is raised. A backoff usually heals
  by itself, and a just-restored interrupted agent may be about to continue on
  its own, so nothing is raised the instant it is seen.
  """
  def grace_ms(:offline, opts), do: Map.get(opts, :offline_grace_ms, 5 * 60_000)
  def grace_ms(_cond, opts), do: Map.get(opts, :grace_ms, 2 * 60_000)

  @doc """
  Fold one observation (`%{agent_id => condition}`) into the first-seen map
  (`%{{agent_id, condition} => ms}`). Returns the new map and the conditions
  that have held for their grace period.
  """
  @spec observe(map(), %{String.t() => t()}, integer(), map()) :: {map(), %{String.t() => t()}}
  def observe(seen, current, now_ms, opts \\ %{}) do
    seen = Map.new(current, fn {aid, c} -> {{aid, c}, Map.get(seen, {aid, c}, now_ms)} end)

    confirmed =
      for {aid, c} <- current,
          now_ms - Map.fetch!(seen, {aid, c}) >= grace_ms(c, opts),
          into: %{},
          do: {aid, c}

    {seen, confirmed}
  end

  @doc """
  What changed between the raised set and the confirmed set: items to raise
  (new, or the agent's condition changed) and items to settle (cleared, or
  replaced). Both as `{agent_id, condition}` lists.
  """
  @spec changes(%{String.t() => t()}, %{String.t() => t()}) ::
          {[{String.t(), t()}], [{String.t(), t()}]}
  def changes(raised, confirmed) do
    to_raise = Enum.reject(confirmed, fn {aid, c} -> Map.get(raised, aid) == c end)
    to_settle = Enum.reject(raised, fn {aid, c} -> Map.get(confirmed, aid) == c end)
    {Enum.sort(to_raise), Enum.sort(to_settle)}
  end

  # ── words ───────────────────────────────────────────────────────────────

  @doc "The inbox item id for an agent in a condition."
  def item_id(agent_id, cond), do: "stuck:#{cond}:#{agent_id}"

  @doc "The marker a condition's slide carries in its permalink."
  def msg_id(cond), do: "stuck-#{cond}"

  @doc "The condition in one or two words — the Agents row and the card eyebrow."
  def word(:interrupted), do: "Interrupted"
  def word(:signed_out), do: "Signed out"
  def word(:quarantined), do: "Quarantined"
  def word(:failed_turn), do: "Turn failed"
  def word(:offline), do: "Offline"
  def word(:plan_limit), do: "At plan limit"
  def word(_), do: nil

  @doc """
  The decisive sentence: WHY it stopped, then the CONSEQUENCE. `who` is the
  agent's name, `account` the identity it bills.
  """
  def label(:interrupted, who, _account),
    do:
      "A server restart cut #{who}'s last turn off and nothing picked it back up, " <>
        "so its work is paused until someone continues it."

  def label(:signed_out, who, account),
    do:
      "#{who} is signed out of #{account || "its account"}, so no turn can run; " <>
        "what you send it waits in its queue."

  def label(:quarantined, who, _account),
    do:
      "#{who} crashed over and over and was quarantined, so it won't restart on its own; " <>
        "its conversation is kept."

  def label(:failed_turn, who, _account),
    do:
      "#{who}'s last turn failed after its retries and the prompt is still unanswered; " <>
        "nothing will try it again."

  def label(:offline, who, _account),
    do:
      "#{who}'s harness has been offline for minutes, so it can't take work; " <>
        "nothing it was given is lost."

  @doc """
  The one action, as `{kind, words}`: `:continue` (re-drive here), `:account`
  (the account's page), or `:chat` (the agent's own chat).
  """
  def action(:interrupted, _account), do: {:continue, "Continue re-runs the unanswered prompt."}

  def action(:signed_out, account),
    do: {:account, "Open #{account || "the account"} and sign it in again."}

  def action(:quarantined, _),
    do: {:chat, "Open its chat and restart it once the cause is fixed."}

  def action(:failed_turn, _), do: {:chat, "Open its chat and resend the prompt."}
  def action(:offline, _), do: {:chat, "Open its chat and restart it."}

  @doc "What the chief of staff may do about a condition on its own."
  def may_do(:interrupted, id), do: "continue it (agent action=continue target=#{id})"

  def may_do(:signed_out, id),
    do:
      "move it to an account its owner permitted as a fallback (agent action=switch " <>
        "target=#{id} account=…); signing in is the human's"

  def may_do(:quarantined, id),
    do:
      "restart it once (agent action=restart target=#{id}) if the cause looks transient; " <>
        "otherwise tell the human"

  def may_do(:failed_turn, id),
    do: "re-run it (agent action=continue target=#{id}) if the failure looks transient"

  def may_do(:offline, id), do: "restart it (agent action=restart target=#{id})"

  def may_do(:plan_limit, _id),
    do: "nothing on your own — no permitted account can take its work; tell the human"

  # ── the wake ────────────────────────────────────────────────────────────

  @doc """
  May the chief of staff be woken? `ctx`: `enabled?`, `system` (its summary,
  nil when the identity has none), `system_condition`, `system_limited?`,
  `disk_down?`. `:ok`, or `{:no, reason}` — a woken model that can't act
  spends plan usage for nothing.
  """
  @spec can_wake(map()) :: :ok | {:no, atom()}
  def can_wake(ctx) do
    cond do
      ctx[:enabled?] != true ->
        {:no, :off}

      is_nil(ctx[:system]) ->
        {:no, :no_chief}

      ctx[:disk_down?] == true ->
        {:no, :disk_down}

      not is_nil(ctx[:system_condition]) ->
        {:no, :chief_stuck}

      ctx[:system_limited?] == true or ctx[:system][:status] == :rate_limited ->
        {:no, :chief_limited}

      true ->
        :ok
    end
  end

  @doc """
  The ONE batched message for the chief of staff: each entry
  (`%{id, name, condition, account}`) by id, its condition, and what it may do.
  Sender-stamped as Loopyard's, so it can never answer a pending decision.
  """
  @spec wake_text([map()]) :: String.t()
  def wake_text(entries) do
    lines =
      entries
      |> Enum.sort_by(& &1.id)
      |> Enum.map_join("\n", fn e ->
        "- #{e.name} [#{e.id}]#{account(e)}: #{String.downcase(word(e.condition))}. " <>
          "You may #{may_do(e.condition, e.id)}."
      end)

    text =
      "Fleet watch — #{count(entries)} need attention:\n#{lines}\n\n" <>
        "Fix what you may, then tell the user in one line what you did. Spending on an " <>
        "account nobody permitted, deleting work and answering a decision stay the human's."

    Thread.tag_from(text, Thread.system_sender())
  end

  defp count([_]), do: "1 agent"
  defp count(list), do: "#{length(list)} agents"

  defp account(%{account: a}) when is_binary(a), do: " (account #{a})"
  defp account(_), do: ""
end
