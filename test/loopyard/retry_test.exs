defmodule Loopyard.RetryTest do
  use ExUnit.Case, async: true

  alias Loopyard.Retry

  # Helper: a function that counts how many times it's invoked and
  # returns a scripted sequence of results. Lets us assert exact
  # attempt counts without real sleeps.
  defp scripted(results) do
    {:ok, agent} = Agent.start_link(fn -> {0, results} end)

    fn ->
      Agent.get_and_update(agent, fn {n, [head | tail]} -> {head, {n + 1, tail}} end)
    end
  end

  # Track total calls by using a counter ref.
  defp track_calls do
    ref = :counters.new(1, [:atomics])
    {ref, fn -> :counters.add(ref, 1, 1) end}
  end

  defp calls(ref), do: :counters.get(ref, 1)

  # Record sleep invocations so we can assert the backoff schedule
  # without actually sleeping.
  defp record_sleeps do
    {:ok, pid} = Agent.start_link(fn -> [] end)
    {pid, fn ms -> Agent.update(pid, &[ms | &1]) end}
  end

  defp sleeps(pid), do: Agent.get(pid, &Enum.reverse(&1))

  describe "run/2 success" do
    test "returns {:ok, value} on first try without sleeping" do
      {sleep_pid, sleep_fn} = record_sleeps()
      {counter, count_fn} = track_calls()

      fun = fn ->
        count_fn.()
        {:ok, :result}
      end

      assert {:ok, :result} =
               Retry.run(fun,
                 max_attempts: 3,
                 backoff: {:custom, [100, 300, 900]},
                 sleep: sleep_fn
               )

      assert calls(counter) == 1
      assert sleeps(sleep_pid) == []
    end

    test "returns {:ok, value} after transient failures" do
      {sleep_pid, sleep_fn} = record_sleeps()
      script = scripted([{:error, :boom}, {:error, :boom}, {:ok, :win}])

      assert {:ok, :win} =
               Retry.run(script,
                 max_attempts: 3,
                 backoff: {:custom, [100, 300, 900]},
                 sleep: sleep_fn
               )

      # Two failures => two sleeps, at schedule positions 1 and 2.
      assert sleeps(sleep_pid) == [100, 300]
    end
  end

  describe "run/2 exhaustion" do
    test "returns last error after max_attempts" do
      {sleep_pid, sleep_fn} = record_sleeps()
      {counter, count_fn} = track_calls()

      fun = fn ->
        count_fn.()
        {:error, :always_fails}
      end

      assert {:error, :always_fails} =
               Retry.run(fun,
                 max_attempts: 3,
                 backoff: {:custom, [100, 300, 900]},
                 sleep: sleep_fn
               )

      # 3 attempts total. Sleep happens between attempts only — 2 sleeps.
      assert calls(counter) == 3
      assert sleeps(sleep_pid) == [100, 300]
    end

    test "max_attempts: 1 makes zero sleeps and zero retries" do
      {sleep_pid, sleep_fn} = record_sleeps()
      {counter, count_fn} = track_calls()

      fun = fn ->
        count_fn.()
        {:error, :nope}
      end

      assert {:error, :nope} =
               Retry.run(fun,
                 max_attempts: 1,
                 backoff: {:custom, [100]},
                 sleep: sleep_fn
               )

      assert calls(counter) == 1
      assert sleeps(sleep_pid) == []
    end
  end

  describe "run/2 non-transient" do
    test "non-transient error short-circuits without retry" do
      {sleep_pid, sleep_fn} = record_sleeps()
      {counter, count_fn} = track_calls()

      fun = fn ->
        count_fn.()
        {:error, "No such container: nope"}
      end

      transient? = fn reason ->
        is_binary(reason) and String.contains?(reason, "connection refused")
      end

      assert {:error, "No such container: nope"} =
               Retry.run(fun,
                 max_attempts: 5,
                 backoff: {:custom, [100, 300, 900]},
                 transient?: transient?,
                 sleep: sleep_fn
               )

      # No retry, no sleep.
      assert calls(counter) == 1
      assert sleeps(sleep_pid) == []
    end

    test "transient? classifier governs retry vs give-up" do
      {sleep_pid, sleep_fn} = record_sleeps()

      # First error is transient, second is not.
      script = scripted([{:error, :retry_me}, {:error, :fatal}])

      transient? = fn
        :retry_me -> true
        _ -> false
      end

      assert {:error, :fatal} =
               Retry.run(script,
                 max_attempts: 5,
                 backoff: {:custom, [50]},
                 transient?: transient?,
                 sleep: sleep_fn
               )

      # One retry-inducing failure → one sleep. Then the non-transient
      # failure short-circuits immediately.
      assert sleeps(sleep_pid) == [50]
    end
  end

  describe "run/2 passthrough" do
    test "non-{:ok}/non-{:error} return values pass through unchanged" do
      # Matches call sites that might return naked values during refactors.
      # We don't want to wrap them silently.
      assert :weird = Retry.run(fn -> :weird end, max_attempts: 3, backoff: {:fixed, 1})
    end
  end

  describe "backoff_ms/2" do
    test "custom schedule returns each value in order" do
      assert Retry.backoff_ms(1, {:custom, [100, 300, 900]}) == 100
      assert Retry.backoff_ms(2, {:custom, [100, 300, 900]}) == 300
      assert Retry.backoff_ms(3, {:custom, [100, 300, 900]}) == 900
    end

    test "custom schedule clamps past the list to the last element" do
      assert Retry.backoff_ms(4, {:custom, [100, 300, 900]}) == 900
      assert Retry.backoff_ms(99, {:custom, [100, 300, 900]}) == 900
    end

    test "exponential: base * 2^(n-1), truncated to int" do
      # Matches the pre-existing ChatAgent schedule exactly.
      assert Retry.backoff_ms(1, {:exponential, 2_000}) == 2_000
      assert Retry.backoff_ms(2, {:exponential, 2_000}) == 4_000
      assert Retry.backoff_ms(3, {:exponential, 2_000}) == 8_000
      assert Retry.backoff_ms(4, {:exponential, 2_000}) == 16_000
      assert Retry.backoff_ms(5, {:exponential, 2_000}) == 32_000
    end

    test "exponential with base 0 stays 0" do
      assert Retry.backoff_ms(1, {:exponential, 0}) == 0
      assert Retry.backoff_ms(5, {:exponential, 0}) == 0
    end

    test "fixed schedule returns ms regardless of attempt" do
      assert Retry.backoff_ms(1, {:fixed, 500}) == 500
      assert Retry.backoff_ms(17, {:fixed, 500}) == 500
    end
  end

  describe "run/2 backoff integration" do
    test "exponential schedule matches ChatAgent shape" do
      {sleep_pid, sleep_fn} = record_sleeps()

      fun = fn -> {:error, :crash} end

      assert {:error, :crash} =
               Retry.run(fun,
                 max_attempts: 5,
                 backoff: {:exponential, 100},
                 sleep: sleep_fn
               )

      # 5 attempts → 4 sleeps at positions 1..4.
      assert sleeps(sleep_pid) == [100, 200, 400, 800]
    end
  end
end
