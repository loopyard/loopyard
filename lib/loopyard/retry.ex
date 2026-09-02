defmodule Loopyard.Retry do
  @moduledoc """
  Retry helper that consolidates ad-hoc backoff loops in the codebase.

  Before this module, `Docker.docker/2` had its own 3-attempt retry with a
  hardcoded 100/300/900 ms backoff, and `ChatAgent` had its own exponential
  crash-recovery backoff of `base * 2^(n-1)` capped at 5 attempts. Two
  shapes of the same idea: try a thing, wait on failure, give up eventually.

  Move #7d in `plans/archive/coordination-hardening.md` narrows the circuit-breaker
  design down to this: pull the shared mechanics into one place so the delay
  schedule and attempt cap are in one module, not duplicated at each call
  site.

  ## Synchronous usage — `run/2`

      Retry.run(fn -> Docker.call() end,
        max_attempts: 3,
        backoff: {:custom, [100, 300, 900]},
        transient?: &transient_error?/1
      )

  Returns:

    * `{:ok, value}` — the function returned `{:ok, value}` on some attempt.
    * the raw `{:error, reason}` the function returned — if the error was
      classified non-transient, or we burned through `max_attempts`.

  The error shape is returned verbatim so callers don't need to unwrap a
  `{:max_attempts, ...}` / `{:non_transient, ...}` envelope. This keeps the
  retry helper drop-in for call sites that already propagate `{:error, _}`
  tuples up the stack.

  ## Asynchronous / state-machine usage — `backoff_ms/2`

  Some callers (e.g. `ChatAgent` crash recovery) can't block inside a
  synchronous `run/2` call: the next attempt happens on a future GenServer
  message, with other traffic interleaved. Those callers use `backoff_ms/2`
  to compute the next delay and manage the retry state themselves:

      delay = Retry.backoff_ms(attempt_number, {:exponential, base_ms})

  Exposing the delay calculator separately means both retry shapes share
  the same schedule math. If we change how exponential backoff behaves,
  both call sites change together.

  ## Backoff schedules

  Three shapes supported:

    * `{:custom, [d1, d2, ...]}` — explicit list. `backoff_ms(n, ...)`
      returns `Enum.at(list, n - 1)`, falling back to the last element
      for `n > length(list)`. Matches the old `Docker` schedule.
    * `{:exponential, base_ms}` — `base_ms * 2^(n - 1)`. Matches the old
      `ChatAgent` schedule.
    * `{:fixed, ms}` — every attempt waits the same `ms`. Included because
      it's the third obvious shape; nothing in the tree uses it yet.

  Backoff values are `trunc`'d to integers, matching the existing
  `ChatAgent` rounding behavior (`:math.pow/2` returns a float).
  """

  @typedoc "Schedule specifier passed via the `:backoff` option or to `backoff_ms/2`."
  @type schedule ::
          {:custom, [non_neg_integer()]}
          | {:exponential, non_neg_integer()}
          | {:fixed, non_neg_integer()}

  @typedoc "Options accepted by `run/2`."
  @type run_opts :: [
          max_attempts: pos_integer(),
          backoff: schedule(),
          transient?: (term() -> boolean()),
          sleep: (non_neg_integer() -> any())
        ]

  @doc """
  Run `fun` with retry semantics.

  `fun` must return `{:ok, value}` on success or `{:error, reason}` on
  failure. Any other return value is passed through unchanged.

  Options:

    * `:max_attempts` (required) — total attempts, including the first one.
    * `:backoff` (required) — a `t:schedule/0`. The delay between attempt
      `n` and attempt `n + 1` is `backoff_ms(n, schedule)`.
    * `:transient?` — a one-arg function that receives the `reason` from an
      `{:error, reason}` return. Truthy → retry (subject to `:max_attempts`).
      Falsy → give up immediately, returning the error verbatim. Defaults
      to `fn _ -> true end` (always retry).
    * `:sleep` — sleep function. Defaults to `Process.sleep/1`. Override in
      tests to keep them fast.

  On exhaust or non-transient failure, the original `{:error, reason}` is
  returned unchanged. This matches how both pre-existing retry sites
  surface their final error — no envelope struct.
  """
  @spec run((-> result), run_opts()) :: result when result: term()
  def run(fun, opts) when is_function(fun, 0) do
    max_attempts = Keyword.fetch!(opts, :max_attempts)
    backoff = Keyword.fetch!(opts, :backoff)
    transient? = Keyword.get(opts, :transient?, fn _ -> true end)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)

    do_run(fun, 1, max_attempts, backoff, transient?, sleep)
  end

  defp do_run(fun, attempt, max_attempts, backoff, transient?, sleep) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        cond do
          attempt >= max_attempts ->
            err

          not transient?.(reason) ->
            err

          true ->
            sleep.(backoff_ms(attempt, backoff))
            do_run(fun, attempt + 1, max_attempts, backoff, transient?, sleep)
        end

      other ->
        other
    end
  end

  @doc """
  Compute the delay (ms) between attempt `n` and attempt `n + 1` for a
  given schedule.

  `attempt` is 1-based: `backoff_ms(1, _)` is the delay after the first
  failure, `backoff_ms(2, _)` after the second, and so on.

  For `{:custom, list}` schedules with `n > length(list)`, the last
  element is reused so callers don't need to special-case a specific max.

  ## Examples

      iex> Loopyard.Retry.backoff_ms(1, {:custom, [100, 300, 900]})
      100
      iex> Loopyard.Retry.backoff_ms(2, {:custom, [100, 300, 900]})
      300
      iex> Loopyard.Retry.backoff_ms(9, {:custom, [100, 300, 900]})
      900

      iex> Loopyard.Retry.backoff_ms(1, {:exponential, 2_000})
      2_000
      iex> Loopyard.Retry.backoff_ms(3, {:exponential, 2_000})
      8_000

      iex> Loopyard.Retry.backoff_ms(5, {:fixed, 500})
      500
  """
  @spec backoff_ms(pos_integer(), schedule()) :: non_neg_integer()
  def backoff_ms(attempt, {:custom, list})
      when is_integer(attempt) and attempt >= 1 and is_list(list) and list != [] do
    case Enum.at(list, attempt - 1) do
      nil -> List.last(list)
      ms -> ms
    end
  end

  def backoff_ms(attempt, {:exponential, base_ms})
      when is_integer(attempt) and attempt >= 1 and is_integer(base_ms) and base_ms >= 0 do
    (base_ms * :math.pow(2, attempt - 1)) |> trunc()
  end

  def backoff_ms(attempt, {:fixed, ms})
      when is_integer(attempt) and attempt >= 1 and is_integer(ms) and ms >= 0 do
    ms
  end
end
