defmodule Loopyard.ChatAgent.PendingDrain do
  @moduledoc """
  When a scheduled drain of `pending_sends` should run, retry, or give up.

  Pure decision, no side effects — the caller performs them. Split out of
  `ChatAgent` because the rule is subtle enough to deserve reading on its own,
  and because getting it wrong STRANDS a user's message: it isn't lost (it sits
  in the queue, visible as "Queued"), it simply never moves, which is a much
  harder failure to spot than a dropped one.

  The rule:

    * Nothing queued → done.
    * `:idle` or `:booting` → drain now. `:booting` matters: it's the state set
      while respawning a harness the idle reaper stopped, which is the single
      most common reason a queue exists at drain time. Excluding it meant the
      drain fired mid-respawn and dropped itself.
    * Anything else → RETRY on a bounded backoff. A running turn drains on
      completion, but nothing guarantees a completion is coming; a degraded or
      wedged status has no such event. The old code dropped the timer here and
      the queue sat forever.
  """

  # Exponential from 2s over six attempts spans a couple of minutes — long
  # enough to outlast a slow harness respawn, bounded so it can't spin.
  @max_retries 6
  @base_ms 2_000

  @type decision ::
          :done | :drain | {:retry, pos_integer(), pos_integer()} | {:give_up, pos_integer()}

  @spec decide(map()) :: decision()
  def decide(%{pending_sends: []}), do: :done

  def decide(%{status: status}) when status in [:idle, :booting], do: :drain

  def decide(state) do
    attempt = Map.get(state, :drain_attempts, 0) + 1

    if attempt <= @max_retries do
      {:retry, attempt, Loopyard.Retry.backoff_ms(attempt, {:exponential, @base_ms})}
    else
      {:give_up, attempt}
    end
  end

  @spec max_retries() :: pos_integer()
  def max_retries, do: @max_retries
end
